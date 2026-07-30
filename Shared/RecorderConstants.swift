//  RecorderConstants.swift
//  Shared constants and models compiled into both App and BroadcastExtension targets.

import Foundation

// MARK: - Constants

enum RecorderConstants {
    static let appGroup = "group.com.musiciansfriend.mobile.app.sfmc"
    static let broadcastBundleId = "com.musiciansfriend.mobile.app.broadcast"
    static let siteURL = "https://frontend-env-dev-satellica.vercel.app"

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
    static var manifestURL: URL {
        containerURL.appendingPathComponent("manifest.json")
    }

    // UserDefaults keys (shared via App Group)
    static let stopRequestedKey = "stop_requested"
    static let broadcastStatusKey = "broadcast_status"
    static let sessionIdKey = "current_session_id"
    static let returnURLKey = "return_url"

    // Darwin notification names
    static let chunkReadyNotification = "com.satellica.recorder.chunk.ready" as CFString
    static let broadcastStartedNotification = "com.satellica.recorder.broadcast.started" as CFString
    static let broadcastFinishedNotification = "com.satellica.recorder.broadcast.finished" as CFString

    // Recording parameters
    static let chunkDuration: TimeInterval = 8       // seconds per chunk
    static let videoBitRate: Int = 800_000            // 800 Kbps — ~800 KB per 8s chunk
    static let frameRate: Int = 30
    static let minFreeDisk: Int64 = 200_000_000       // 200 MB
}

// MARK: - Chunk Manifest

struct ChunkInfo: Codable {
    let index: Int
    let fileName: String
    var status: ChunkStatus

    enum ChunkStatus: String, Codable {
        case recording, ready, uploading, uploaded, failed
    }
}

struct RecordingManifest: Codable {
    let sessionId: String
    let startedAt: Date
    var status: String   // "recording", "stopped", "completed"
    var chunks: [ChunkInfo]

    static func load() -> RecordingManifest? {
        guard let data = try? Data(contentsOf: RecorderConstants.manifestURL) else { return nil }
        return try? JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: RecorderConstants.manifestURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: RecorderConstants.manifestURL)
    }
}
