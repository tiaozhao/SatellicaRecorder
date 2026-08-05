//  RecorderConstants.swift
//  Shared constants and models compiled into both App and BroadcastExtension targets.

import Foundation
import Darwin

// MARK: - Constants

enum RecorderEnvironment: String, Codable {
    case development
    case production

    var siteBaseURL: URL {
        switch self {
        case .development:
            return URL(string: "https://frontend-env-dev-satellica.vercel.app")!
        case .production:
            return URL(string: "https://app.satellica.io")!
        }
    }
}

enum RecorderConstants {
    static let appGroup = "group.io.satellica.recorder.shared"
    static let broadcastBundleId = "io.satellica.recorder.broadcast"
    static let customURLScheme = "satellica-recorder"
    static let environment: RecorderEnvironment = .development
    static var siteBaseURL: URL { environment.siteBaseURL }
    static var siteURL: String { siteBaseURL.absoluteString }

    // Keep nil for the normal home/deep-link launch flow.
    static let testInterviewURL: URL? = nil

    // App Group container paths
    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            // Fallback to Documents (should never happen with correct entitlements)
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        return url
    }
    static var chunksDirectory: URL {
        containerURL.appendingPathComponent("chunks", isDirectory: true)
    }
    static var chunkMetadataDirectory: URL {
        containerURL.appendingPathComponent("chunk-metadata", isDirectory: true)
    }
    static var manifestURL: URL {
        containerURL.appendingPathComponent("manifest.json")
    }
    static var manifestLockURL: URL {
        containerURL.appendingPathComponent("manifest.lock")
    }
    static var uploadContextURL: URL {
        containerURL.appendingPathComponent("upload-context.json")
    }
    static var signedURLCacheURL: URL {
        containerURL.appendingPathComponent("signed-url-cache.json")
    }
    static var diagnosticsURL: URL {
        containerURL.appendingPathComponent("recorder-diagnostics.log")
    }
    static var diagnosticsLockURL: URL {
        containerURL.appendingPathComponent("recorder-diagnostics.lock")
    }

    // UserDefaults keys (shared via App Group)
    static let stopRequestedKey = "stop_requested"
    static let broadcastStatusKey = "broadcast_status"
    static let broadcastHeartbeatMsKey = "broadcast_heartbeat_ms"
    static let sessionIdKey = "current_session_id"
    static let returnURLKey = "return_url"
    static let interviewLinkKey = "interview_link"
    static let studyIdKey = "study_id"
    static let siteStopCompletedKey = "site_stop_completed"
    static let siteStopRecordingIdKey = "site_stop_recording_id"

    // Darwin notification names
    static let chunkReadyNotification = "com.satellica.recorder.chunk.ready" as CFString
    static let broadcastStartedNotification = "com.satellica.recorder.broadcast.started" as CFString
    static let broadcastFinishedNotification = "com.satellica.recorder.broadcast.finished" as CFString

    // Recording parameters
    static let chunkDuration: TimeInterval = 8       // seconds per chunk
    static let videoBitRate: Int = 800_000            // 800 Kbps — ~800 KB per 8s chunk
    static let frameRate: Int = 30
    static let minFreeDisk: Int64 = 200_000_000       // 200 MB

    static var isAppGroupContainerAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }
}

// MARK: - Cross-process diagnostics

/// Persistent diagnostics shared by the host app and ReplayKit extension.
/// Callers must never pass tokens or signed URLs in `fields`.
enum RecorderLog {
    private static let maxBytes: Int64 = 5_000_000
    private static let processLock = NSLock()

    static func write(_ source: String, _ event: String, _ fields: [String: CustomStringConvertible] = [:]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let details = fields.keys.sorted().map { key in
            let raw = fields[key]?.description ?? "nil"
            let safe = raw.replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\(key)=\(safe)"
        }.joined(separator: " ")
        let line = "\(formatter.string(from: Date())) pid=\(getpid()) source=\(source) " +
            "event=\(event)\(details.isEmpty ? "" : " \(details)")\n"

        processLock.lock()
        defer { processLock.unlock() }
        withLock {
            let fileSize = ((try? FileManager.default.attributesOfItem(
                atPath: RecorderConstants.diagnosticsURL.path
            )[.size]) as? NSNumber)?.int64Value ?? 0
            if fileSize > maxBytes {
                try? FileManager.default.removeItem(at: RecorderConstants.diagnosticsURL)
            }

            let data = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: RecorderConstants.diagnosticsURL.path) {
                try? data.write(
                    to: RecorderConstants.diagnosticsURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                return
            }
            guard let handle = try? FileHandle(forWritingTo: RecorderConstants.diagnosticsURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func withLock(_ body: () -> Void) {
        let descriptor = RecorderConstants.diagnosticsLockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            body()
            return
        }
        Darwin.lockf(descriptor, F_LOCK, 0)
        defer {
            Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
        }
        body()
    }
}

// MARK: - Chunk Manifest

struct ChunkInfo: Codable {
    let index: Int
    let fileName: String
    var status: ChunkStatus
    var fileSize: Int64? = nil
    var duration: TimeInterval? = nil
    var sha256: String? = nil
    var startOffsetMs: Int64? = nil

    enum ChunkStatus: String, Codable {
        case recording, ready, uploading, uploaded, failed, serverMissing, dataLost
    }
}

struct RecordingManifest: Codable {
    let sessionId: String
    let startedAt: Date
    var status: String   // "recording", "stopped", "completed"
    var chunks: [ChunkInfo]
    var interruptedAtMs: Int64? = nil
    var interruptedReason: String? = nil

    static func load() -> RecordingManifest? {
        RecordingManifestStore.load()
    }

    @discardableResult
    func save() -> Bool {
        RecordingManifestStore.mergeAndSave(self)
    }

    static func clear() {
        RecordingManifestStore.clear()
    }
}

/// Cross-process manifest storage shared by the app and broadcast extension.
/// The lock protects the complete read/merge/write transaction, while the
/// merge prevents a stale extension snapshot from regressing upload progress.
enum RecordingManifestStore {
    static func load() -> RecordingManifest? {
        withLock { loadUnlocked() }
    }

    @discardableResult
    static func mergeAndSave(_ incoming: RecordingManifest) -> Bool {
        withLock {
            var merged = incoming

            if let current = loadUnlocked(), current.sessionId == incoming.sessionId {
                merged.status = laterSessionStatus(current.status, incoming.status)
                merged.interruptedAtMs = incoming.interruptedAtMs ?? current.interruptedAtMs
                merged.interruptedReason = incoming.interruptedReason ?? current.interruptedReason

                var chunksByIndex = Dictionary(uniqueKeysWithValues: current.chunks.map { ($0.index, $0) })
                for chunk in incoming.chunks {
                    if let existing = chunksByIndex[chunk.index] {
                        chunksByIndex[chunk.index] = merge(existing: existing, incoming: chunk)
                    } else {
                        chunksByIndex[chunk.index] = chunk
                    }
                }
                merged.chunks = chunksByIndex.values.sorted { $0.index < $1.index }
            }

            return saveUnlocked(merged)
        }
    }

    /// Atomically merges one chunk into the latest manifest on disk. This is
    /// the recorder-facing API: it fills metadata without allowing a stale
    /// recorder state to regress upload progress already persisted by the app.
    @discardableResult
    static func upsertChunk(sessionId: String, chunk incoming: ChunkInfo) -> Bool {
        withLock {
            guard var current = loadUnlocked(), current.sessionId == sessionId else { return false }
            if let index = current.chunks.firstIndex(where: { $0.index == incoming.index }) {
                current.chunks[index] = merge(existing: current.chunks[index], incoming: incoming)
            } else {
                current.chunks.append(incoming)
                current.chunks.sort { $0.index < $1.index }
            }
            guard saveUnlocked(current),
                  let verified = loadUnlocked(),
                  verified.sessionId == sessionId,
                  verified.chunks.contains(where: { $0.index == incoming.index }) else { return false }
            return true
        }
    }

    /// Atomically mutates one chunk in the latest manifest. The uploader uses
    /// this for authoritative state transitions such as uploading → uploaded
    /// and uploaded → serverMissing.
    @discardableResult
    static func updateChunk(
        sessionId: String,
        index chunkIndex: Int,
        _ mutation: (inout ChunkInfo) -> Void
    ) -> Bool {
        withLock {
            guard var current = loadUnlocked(), current.sessionId == sessionId,
                  let index = current.chunks.firstIndex(where: { $0.index == chunkIndex }) else {
                return false
            }
            mutation(&current.chunks[index])
            guard saveUnlocked(current),
                  let verified = loadUnlocked(),
                  verified.sessionId == sessionId,
                  verified.chunks.contains(where: { $0.index == chunkIndex }) else { return false }
            return true
        }
    }

    /// Atomically updates recording-level state and verifies the exact value
    /// that was persisted. This prevents a failed final `stopped` write from
    /// leaving a fully-uploaded recording permanently unable to complete.
    @discardableResult
    static func updateSessionStatus(sessionId: String, status: String) -> Bool {
        withLock {
            guard var current = loadUnlocked(), current.sessionId == sessionId else { return false }
            let targetStatus = laterSessionStatus(current.status, status)
            current.status = targetStatus
            guard saveUnlocked(current),
                  let verified = loadUnlocked(),
                  verified.sessionId == sessionId,
                  verified.status == targetStatus else { return false }
            return true
        }
    }

    static func clear() {
        withLock {
            try? FileManager.default.removeItem(at: RecorderConstants.manifestURL)
        }
    }

    private static func loadUnlocked() -> RecordingManifest? {
        guard let data = try? Data(contentsOf: RecorderConstants.manifestURL) else { return nil }
        return try? JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    private static func saveUnlocked(_ manifest: RecordingManifest) -> Bool {
        guard let data = try? JSONEncoder().encode(manifest) else { return false }
        do {
            try data.write(
                to: RecorderConstants.manifestURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            print("[RecordingManifestStore] save failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func merge(existing: ChunkInfo, incoming: ChunkInfo) -> ChunkInfo {
        // A successful /complete response may report that an object previously
        // acknowledged by GCS is missing. That server observation must be able
        // to move an uploaded chunk back into the retry state, and the retry
        // must then be allowed to progress again.
        let selected: ChunkInfo
        if incoming.status == .serverMissing || existing.status == .serverMissing {
            selected = incoming
        } else {
            let existingRank = statusRank(existing.status)
            let incomingRank = statusRank(incoming.status)

            // Equal-ranked upload states (uploading/failed) are allowed to move
            // in either direction for retry. Lower-ranked recorder states can
            // never overwrite upload progress already persisted by the app.
            selected = incomingRank >= existingRank ? incoming : existing
        }

        // Status and metadata have different lifecycles. Preserve every durable
        // metadata field even when the status from the other side wins.
        var result = selected
        result.fileSize = incoming.fileSize ?? existing.fileSize
        result.duration = incoming.duration ?? existing.duration
        result.sha256 = incoming.sha256 ?? existing.sha256
        result.startOffsetMs = incoming.startOffsetMs ?? existing.startOffsetMs
        return result
    }

    private static func statusRank(_ status: ChunkInfo.ChunkStatus) -> Int {
        switch status {
        case .recording: return 0
        case .ready: return 1
        case .uploading, .failed: return 2
        case .serverMissing: return 2
        case .uploaded: return 3
        case .dataLost: return 4
        }
    }

    private static func laterSessionStatus(_ lhs: String, _ rhs: String) -> String {
        let rank = ["recording": 0, "stopped": 1, "completed": 2]
        return (rank[rhs, default: -1] >= rank[lhs, default: -1]) ? rhs : lhs
    }

    private static func withLock<T>(_ body: () -> T) -> T {
        let path = RecorderConstants.manifestLockURL.path
        let descriptor = path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }

        guard descriptor >= 0 else { return body() }
        Darwin.lockf(descriptor, F_LOCK, 0)
        defer {
            Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
        }
        return body()
    }
}

// MARK: - Per-chunk metadata journal

/// One independently-written record per chunk. The manifest remains the index
/// used by the uploader, while this journal is the recovery source if a global
/// manifest update is interrupted or contains stale recorder state.
private struct ChunkMetadataRecord: Codable {
    let sessionId: String
    let chunk: ChunkInfo
}

enum ChunkMetadataStore {
    static func load(sessionId: String, index: Int) -> ChunkInfo? {
        let url = metadataURL(for: index)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(ChunkMetadataRecord.self, from: data),
              record.sessionId == sessionId,
              record.chunk.index == index else { return nil }
        return record.chunk
    }

    /// Loads every independently-persisted chunk record for a recording. This
    /// is the recovery path when a chunk journal reached disk but the global
    /// manifest update was interrupted.
    static func loadAll(sessionId: String) -> [ChunkInfo] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: RecorderConstants.chunkMetadataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url -> ChunkInfo? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(ChunkMetadataRecord.self, from: data),
                  record.sessionId == sessionId else { return nil }
            return record.chunk
        }.sorted { $0.index < $1.index }
    }

    @discardableResult
    static func save(sessionId: String, chunk: ChunkInfo) -> Bool {
        ensureDirectory()
        let record = ChunkMetadataRecord(sessionId: sessionId, chunk: chunk)
        guard let data = try? JSONEncoder().encode(record) else { return false }
        do {
            try data.write(
                to: metadataURL(for: chunk.index),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            guard let verified = load(sessionId: sessionId, index: chunk.index) else { return false }
            return verified.fileName == chunk.fileName &&
                verified.startOffsetMs == chunk.startOffsetMs &&
                verified.duration == chunk.duration &&
                verified.fileSize == chunk.fileSize
        } catch {
            return false
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: RecorderConstants.chunkMetadataDirectory)
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: RecorderConstants.chunkMetadataDirectory,
            withIntermediateDirectories: true
        )
    }

    private static func metadataURL(for index: Int) -> URL {
        RecorderConstants.chunkMetadataDirectory
            .appendingPathComponent(String(format: "chunk_%04d.json", index))
    }
}

// MARK: - Native upload handoff

struct NativeUploadContext: Codable, Equatable {
    let environment: RecorderEnvironment
    let recordingId: String
    var uploadToken: String
    var serverEpochMs: Int64
    let chunkSeconds: TimeInterval
    var chunkURLBatch: Int
    var maxChunks: Int?
    var maxChunkBytes: Int64
    let apiOrigin: URL
    let interviewLink: String
    let studyId: String
    let createdAt: Date
    var startedAtDeviceEpochMs: Int64?
    /// `false` means the site ended the interview early. The app uploads every
    /// produced chunk but intentionally does not call `/complete`.
    var siteCompleted: Bool? = nil

    var chunkURLsEndpoint: URL {
        apiOrigin
            .appendingPathComponent("api")
            .appendingPathComponent("recordings")
            .appendingPathComponent(recordingId)
            .appendingPathComponent("chunk-urls")
    }

    var completeEndpoint: URL {
        apiOrigin
            .appendingPathComponent("api")
            .appendingPathComponent("recordings")
            .appendingPathComponent(recordingId)
            .appendingPathComponent("complete")
    }


    var startEndpoint: URL {
        apiOrigin
            .appendingPathComponent("api")
            .appendingPathComponent("recordings")
            .appendingPathComponent("start")
    }
}

enum NativeUploadContextStore {
    static func load() -> NativeUploadContext? {
        guard let data = try? Data(contentsOf: RecorderConstants.uploadContextURL) else { return nil }
        return try? JSONDecoder().decode(NativeUploadContext.self, from: data)
    }

    @discardableResult
    static func save(_ context: NativeUploadContext) -> Bool {
        guard let data = try? JSONEncoder().encode(context) else { return false }
        do {
            try data.write(to: RecorderConstants.uploadContextURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            print("[NativeUploadContextStore] save failed: \(error.localizedDescription)")
            return false
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: RecorderConstants.uploadContextURL)
        try? FileManager.default.removeItem(at: RecorderConstants.signedURLCacheURL)
    }
}
