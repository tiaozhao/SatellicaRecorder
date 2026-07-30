//  SessionManager.swift
//  SatellicaRecorder — recording session lifecycle, deep link handling,
//  Darwin notification listeners, and state coordination.

import SwiftUI

@MainActor
final class SessionManager: ObservableObject {
    @Published var path: [AppRoute] = []
    @Published var isRecording = false
    @Published var broadcastStatus: String = "idle"  // idle, recording, stopped, completed

    let uploader = ChunkUploader.shared

    init() {
        listenForDarwinNotifications()
        uploader.onAllUploaded = { [weak self] in
            self?.broadcastStatus = "completed"
        }
        checkPendingState()
    }

    // MARK: - Deep link handling

    func handleDeepLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let urlPath = components?.path ?? url.path

        if let returnURL = components?.queryItems?.first(where: { $0.name == "return" })?.value {
            let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
            defaults?.set(returnURL, forKey: RecorderConstants.returnURLKey)
            defaults?.synchronize()
        }

        switch urlPath {
        case _ where urlPath.hasSuffix("/recording/start"):
            path = [.start]
        case _ where urlPath.hasSuffix("/recording/stop"):
            requestStop()
            path = [.stop]
        default:
            break
        }
    }

    // MARK: - Recording control

    func triggerStart() {
        // Reset uploader for new session
        uploader.reset()
        broadcastStatus = "idle"

        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set(false, forKey: RecorderConstants.stopRequestedKey)
        defaults?.synchronize()

        BroadcastTriggerButton.trigger()
    }

    func requestStop() {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set(true, forKey: RecorderConstants.stopRequestedKey)
        defaults?.synchronize()
    }

    func returnToWebsite() {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        if let returnURL = defaults?.string(forKey: RecorderConstants.returnURLKey),
           let url = URL(string: returnURL) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: RecorderConstants.siteURL) {
            UIApplication.shared.open(url)
        }
    }

    func openWebsite() {
        if let url = URL(string: RecorderConstants.siteURL) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - State check (cold start / foreground resume)

    func checkPendingState() {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        let status = defaults?.string(forKey: RecorderConstants.broadcastStatusKey) ?? "idle"

        isRecording = (status == "recording")

        // Don't overwrite "completed" with "stopped" if uploads already finished
        if broadcastStatus != "completed" {
            broadcastStatus = status
        }

        // Recovery: upload any pending chunks (handles .uploading stuck chunks too)
        uploader.uploadPendingChunks()

        // Also check completion in case all uploads finished while app was dead
        recheckCompletion()

        if status == "stopped" && path.isEmpty && broadcastStatus != "completed" {
            path = [.stop]
        }
    }

    // MARK: - Darwin notification listeners

    private func listenForDarwinNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            let mgr = Unmanaged<SessionManager>.fromOpaque(obs).takeUnretainedValue()
            Task { @MainActor in mgr.onBroadcastStarted() }
        }, RecorderConstants.broadcastStartedNotification, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            let mgr = Unmanaged<SessionManager>.fromOpaque(obs).takeUnretainedValue()
            Task { @MainActor in mgr.onBroadcastFinished() }
        }, RecorderConstants.broadcastFinishedNotification, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            let mgr = Unmanaged<SessionManager>.fromOpaque(obs).takeUnretainedValue()
            Task { @MainActor in mgr.onChunkReady() }
        }, RecorderConstants.chunkReadyNotification, nil, .deliverImmediately)
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    private func onBroadcastStarted() {
        // Reset ALL state for the new session — this is the single reliable reset point.
        // Even if triggerStart() wasn't called (e.g. user tapped broadcast picker directly),
        // this notification always fires when a new broadcast begins.
        uploader.reset()
        isRecording = true
        broadcastStatus = "recording"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.returnToWebsite()
        }
    }

    private func onBroadcastFinished() {
        isRecording = false

        // Don't overwrite "completed" if uploads already finished
        if broadcastStatus != "completed" {
            broadcastStatus = "stopped"
        }

        uploader.uploadPendingChunks()

        // Check if all uploads were already done before "stopped" arrived
        recheckCompletion()

        if !path.contains(.stop) {
            path = [.stop]
        }
    }

    private func onChunkReady() {
        uploader.uploadPendingChunks()
    }

    /// Re-read manifest and trigger completion if all chunks uploaded.
    /// Covers the race where uploads finish before the "stopped" signal arrives.
    private func recheckCompletion() {
        guard broadcastStatus != "completed" else { return }
        guard var manifest = RecordingManifest.load() else { return }

        let allUploaded = manifest.chunks.allSatisfy { $0.status == .uploaded }
        guard allUploaded && !manifest.chunks.isEmpty else { return }

        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        let status = defaults?.string(forKey: RecorderConstants.broadcastStatusKey) ?? "idle"
        guard status == "stopped" else { return }

        manifest.status = "completed"
        manifest.save()
        uploader.isUploading = false
        broadcastStatus = "completed"
    }
}
