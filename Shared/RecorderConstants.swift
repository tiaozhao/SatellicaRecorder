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
    static var recordingsDirectory: URL {
        containerURL.appendingPathComponent("recordings", isDirectory: true)
    }
    static func recordingDirectory(_ recordingId: String) -> URL {
        recordingsDirectory.appendingPathComponent(recordingId, isDirectory: true)
    }
    static func chunksDirectory(for recordingId: String) -> URL {
        recordingDirectory(recordingId).appendingPathComponent("chunks", isDirectory: true)
    }
    static func chunkMetadataDirectory(for recordingId: String) -> URL {
        recordingDirectory(recordingId).appendingPathComponent("chunk-metadata", isDirectory: true)
    }
    static func manifestURL(for recordingId: String) -> URL {
        recordingDirectory(recordingId).appendingPathComponent("manifest.json")
    }
    static func manifestLockURL(for recordingId: String) -> URL {
        recordingDirectory(recordingId).appendingPathComponent("manifest.lock")
    }
    static func uploadContextURL(for recordingId: String) -> URL {
        recordingDirectory(recordingId).appendingPathComponent("upload-context.json")
    }
    static func signedURLCacheURL(for recordingId: String) -> URL {
        recordingDirectory(recordingId).appendingPathComponent("signed-url-cache.json")
    }
    static var activeRecordingId: String? {
        UserDefaults(suiteName: appGroup)?.string(forKey: activeRecordingIdKey)
    }
    static var chunksDirectory: URL {
        activeRecordingId.map(chunksDirectory(for:)) ?? containerURL.appendingPathComponent("chunks", isDirectory: true)
    }
    static var chunkMetadataDirectory: URL {
        activeRecordingId.map(chunkMetadataDirectory(for:)) ?? containerURL.appendingPathComponent("chunk-metadata", isDirectory: true)
    }
    static var manifestURL: URL {
        activeRecordingId.map(manifestURL(for:)) ?? containerURL.appendingPathComponent("manifest.json")
    }
    static var manifestLockURL: URL {
        activeRecordingId.map(manifestLockURL(for:)) ?? containerURL.appendingPathComponent("manifest.lock")
    }
    static var uploadContextURL: URL {
        activeRecordingId.map(uploadContextURL(for:)) ?? containerURL.appendingPathComponent("upload-context.json")
    }
    static var signedURLCacheURL: URL {
        activeRecordingId.map(signedURLCacheURL(for:)) ?? containerURL.appendingPathComponent("signed-url-cache.json")
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
    static let activeRecordingIdKey = "active_recording_id"
    static let uploadQueueKey = "authorized_upload_queue"

    // Darwin notification names
    static let chunkReadyNotification = "com.satellica.recorder.chunk.ready" as CFString
    static let broadcastStartedNotification = "com.satellica.recorder.broadcast.started" as CFString
    static let broadcastFinishedNotification = "com.satellica.recorder.broadcast.finished" as CFString
    static let broadcastFailedNotification = "com.satellica.recorder.broadcast.failed" as CFString

    // Recording parameters
    static let chunkDuration: TimeInterval = 8       // seconds per chunk
    static let videoBitRate: Int = 800_000            // 800 Kbps — ~800 KB per 8s chunk
    static let frameRate: Int = 30
    static let minFreeDisk: Int64 = 200_000_000       // emergency stop threshold
    static let minFreeDiskToStart: Int64 = 500_000_000

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
    var partialDataLoss: Bool? = nil

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
    static func load(recordingId: String? = nil) -> RecordingManifest? {
        guard let recordingId = recordingId ?? RecorderConstants.activeRecordingId else { return nil }
        return withLock(recordingId: recordingId) { loadUnlocked(recordingId: recordingId) }
    }

    @discardableResult
    static func mergeAndSave(_ incoming: RecordingManifest) -> Bool {
        ensureRecordingDirectory(incoming.sessionId)
        return withLock(recordingId: incoming.sessionId) {
            var merged = incoming

            if let current = loadUnlocked(recordingId: incoming.sessionId), current.sessionId == incoming.sessionId {
                merged.status = laterSessionStatus(current.status, incoming.status)
                merged.interruptedAtMs = incoming.interruptedAtMs ?? current.interruptedAtMs
                merged.interruptedReason = incoming.interruptedReason ?? current.interruptedReason
                merged.partialDataLoss = incoming.partialDataLoss ?? current.partialDataLoss

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

            return saveUnlocked(merged, recordingId: incoming.sessionId)
        }
    }

    /// Atomically merges one chunk into the latest manifest on disk. This is
    /// the recorder-facing API: it fills metadata without allowing a stale
    /// recorder state to regress upload progress already persisted by the app.
    @discardableResult
    static func upsertChunk(sessionId: String, chunk incoming: ChunkInfo) -> Bool {
        withLock(recordingId: sessionId) {
            guard var current = loadUnlocked(recordingId: sessionId), current.sessionId == sessionId else { return false }
            if let index = current.chunks.firstIndex(where: { $0.index == incoming.index }) {
                current.chunks[index] = merge(existing: current.chunks[index], incoming: incoming)
            } else {
                current.chunks.append(incoming)
                current.chunks.sort { $0.index < $1.index }
            }
            guard saveUnlocked(current, recordingId: sessionId),
                  let verified = loadUnlocked(recordingId: sessionId),
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
        withLock(recordingId: sessionId) {
            guard var current = loadUnlocked(recordingId: sessionId), current.sessionId == sessionId,
                  let index = current.chunks.firstIndex(where: { $0.index == chunkIndex }) else {
                return false
            }
            mutation(&current.chunks[index])
            guard saveUnlocked(current, recordingId: sessionId),
                  let verified = loadUnlocked(recordingId: sessionId),
                  verified.sessionId == sessionId,
                  verified.chunks.contains(where: { $0.index == chunkIndex }) else { return false }
            return true
        }
    }

    @discardableResult
    static func removeChunk(sessionId: String, index chunkIndex: Int) -> Bool {
        withLock(recordingId: sessionId) {
            guard var current = loadUnlocked(recordingId: sessionId), current.sessionId == sessionId else {
                return false
            }
            current.chunks.removeAll { $0.index == chunkIndex }
            return saveUnlocked(current, recordingId: sessionId)
        }
    }

    /// Atomically updates recording-level state and verifies the exact value
    /// that was persisted. This prevents a failed final `stopped` write from
    /// leaving a fully-uploaded recording permanently unable to complete.
    @discardableResult
    static func updateSessionStatus(sessionId: String, status: String) -> Bool {
        withLock(recordingId: sessionId) {
            guard var current = loadUnlocked(recordingId: sessionId), current.sessionId == sessionId else { return false }
            let targetStatus = laterSessionStatus(current.status, status)
            current.status = targetStatus
            guard saveUnlocked(current, recordingId: sessionId),
                  let verified = loadUnlocked(recordingId: sessionId),
                  verified.sessionId == sessionId,
                  verified.status == targetStatus else { return false }
            return true
        }
    }

    @discardableResult
    static func markPartialDataLoss(sessionId: String) -> Bool {
        withLock(recordingId: sessionId) {
            guard var current = loadUnlocked(recordingId: sessionId), current.sessionId == sessionId else {
                return false
            }
            current.partialDataLoss = true
            return saveUnlocked(current, recordingId: sessionId)
        }
    }

    static func clear(recordingId: String? = nil) {
        guard let recordingId = recordingId ?? RecorderConstants.activeRecordingId else { return }
        withLock(recordingId: recordingId) {
            try? FileManager.default.removeItem(at: RecorderConstants.manifestURL(for: recordingId))
        }
    }

    private static func loadUnlocked(recordingId: String) -> RecordingManifest? {
        guard let data = try? Data(contentsOf: RecorderConstants.manifestURL(for: recordingId)) else { return nil }
        return try? JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    private static func saveUnlocked(_ manifest: RecordingManifest, recordingId: String) -> Bool {
        ensureRecordingDirectory(recordingId)
        guard let data = try? JSONEncoder().encode(manifest) else { return false }
        do {
            try data.write(
                to: RecorderConstants.manifestURL(for: recordingId),
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

    private static func ensureRecordingDirectory(_ recordingId: String) {
        try? FileManager.default.createDirectory(
            at: RecorderConstants.recordingDirectory(recordingId),
            withIntermediateDirectories: true
        )
    }

    private static func withLock<T>(recordingId: String, _ body: () -> T) -> T {
        ensureRecordingDirectory(recordingId)
        let path = RecorderConstants.manifestLockURL(for: recordingId).path
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
        let url = metadataURL(sessionId: sessionId, index: index)
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
            at: RecorderConstants.chunkMetadataDirectory(for: sessionId),
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
        ensureDirectory(sessionId: sessionId)
        let record = ChunkMetadataRecord(sessionId: sessionId, chunk: chunk)
        guard let data = try? JSONEncoder().encode(record) else { return false }
        do {
            try data.write(
                to: metadataURL(sessionId: sessionId, index: chunk.index),
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

    static func clear(recordingId: String? = nil) {
        guard let recordingId = recordingId ?? RecorderConstants.activeRecordingId else { return }
        try? FileManager.default.removeItem(at: RecorderConstants.chunkMetadataDirectory(for: recordingId))
    }

    static func remove(sessionId: String, index: Int) {
        try? FileManager.default.removeItem(at: metadataURL(sessionId: sessionId, index: index))
    }

    private static func ensureDirectory(sessionId: String) {
        try? FileManager.default.createDirectory(
            at: RecorderConstants.chunkMetadataDirectory(for: sessionId),
            withIntermediateDirectories: true
        )
    }

    private static func metadataURL(sessionId: String, index: Int) -> URL {
        RecorderConstants.chunkMetadataDirectory(for: sessionId)
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
    var siteCompleted: Bool? = nil
    var sessionStarted: Bool? = nil
    var uploadAuthorized: Bool? = nil
    var stopRequestedBySite: Bool? = nil
    var stopRequestedAtDeviceEpochMs: Int64? = nil

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
    static func load(recordingId: String? = nil) -> NativeUploadContext? {
        guard let recordingId = recordingId ?? RecorderConstants.activeRecordingId,
              let data = try? Data(contentsOf: RecorderConstants.uploadContextURL(for: recordingId)) else { return nil }
        return try? JSONDecoder().decode(NativeUploadContext.self, from: data)
    }

    @discardableResult
    static func save(_ context: NativeUploadContext) -> Bool {
        try? FileManager.default.createDirectory(
            at: RecorderConstants.recordingDirectory(context.recordingId),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(context) else { return false }
        do {
            try data.write(
                to: RecorderConstants.uploadContextURL(for: context.recordingId),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            print("[NativeUploadContextStore] save failed: \(error.localizedDescription)")
            return false
        }
    }

    static func clear(recordingId: String? = nil) {
        guard let recordingId = recordingId ?? RecorderConstants.activeRecordingId else { return }
        try? FileManager.default.removeItem(at: RecorderConstants.uploadContextURL(for: recordingId))
        try? FileManager.default.removeItem(at: RecorderConstants.signedURLCacheURL(for: recordingId))
    }
}

// MARK: - Retained recordings and authorized upload queue

enum RecordingStore {
    static func prepare() {
        try? FileManager.default.createDirectory(
            at: RecorderConstants.recordingsDirectory,
            withIntermediateDirectories: true
        )
        migrateLegacyRecordingIfNeeded()
    }

    static func recordingIds() -> [String] {
        prepare()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: RecorderConstants.recordingsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
            .map(\.lastPathComponent)
            .filter { recordingId in
                // A retained recording must remain discoverable even when its
                // upload context is temporarily unreadable. Eligibility only
                // needs the opaque recordingId; actual upload still requires
                // a valid context and token.
                if let manifest = RecordingManifestStore.load(recordingId: recordingId) {
                    return manifest.sessionId == recordingId
                }
                return NativeUploadContextStore.load(recordingId: recordingId)?.recordingId == recordingId
            }
            .sorted()
    }

    static func setActiveRecordingId(_ recordingId: String?) {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        if let recordingId {
            defaults?.set(recordingId, forKey: RecorderConstants.activeRecordingIdKey)
        } else {
            defaults?.removeObject(forKey: RecorderConstants.activeRecordingIdKey)
        }
        defaults?.synchronize()
    }

    @discardableResult
    static func delete(recordingId: String) -> Bool {
        let directory = RecorderConstants.recordingDirectory(recordingId)
        try? FileManager.default.removeItem(at: directory)
        let removed = !FileManager.default.fileExists(atPath: directory.path)
        UploadQueueStore.remove(recordingId)
        if RecorderConstants.activeRecordingId == recordingId { setActiveRecordingId(nil) }
        return removed
    }

    private static func migrateLegacyRecordingIfNeeded() {
        let legacyManifestURL = RecorderConstants.containerURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: legacyManifestURL),
              let manifest = try? JSONDecoder().decode(RecordingManifest.self, from: data),
              !FileManager.default.fileExists(atPath: RecorderConstants.recordingDirectory(manifest.sessionId).path) else {
            return
        }
        let destination = RecorderConstants.recordingDirectory(manifest.sessionId)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = ["manifest.json", "manifest.lock", "upload-context.json", "signed-url-cache.json", "chunks", "chunk-metadata"]
        for name in names {
            let source = RecorderConstants.containerURL.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.moveItem(at: source, to: target)
        }
        setActiveRecordingId(manifest.sessionId)
        if var context = NativeUploadContextStore.load(recordingId: manifest.sessionId),
           context.siteCompleted == true {
            context.uploadAuthorized = true
            if NativeUploadContextStore.save(context) {
                UploadQueueStore.enqueue(manifest.sessionId)
            }
        }
    }
}

enum UploadQueueStore {
    static func all() -> [String] {
        UserDefaults(suiteName: RecorderConstants.appGroup)?.stringArray(
            forKey: RecorderConstants.uploadQueueKey
        ) ?? []
    }

    static func enqueue(_ recordingId: String) {
        var ids = all()
        guard !ids.contains(recordingId) else { return }
        ids.append(recordingId)
        save(ids)
    }

    static func remove(_ recordingId: String) {
        save(all().filter { $0 != recordingId })
    }

    private static func save(_ ids: [String]) {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set(ids, forKey: RecorderConstants.uploadQueueKey)
        defaults?.synchronize()
    }
}
