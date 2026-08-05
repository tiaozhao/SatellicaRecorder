//  SessionManager.swift
//  SatellicaRecorder — recording session lifecycle, deep link handling,
//  Darwin notification listeners, WebView bridge, and state coordination.

import SwiftUI

@MainActor
final class SessionManager: ObservableObject {
    @Published var path: [AppRoute] = []
    @Published var isRecording = false
    @Published var broadcastStatus: String = "idle"  // idle, recording, stopped, completed

    /// The URL to load in the WebView (set by deep link handler).
    @Published var webViewURL: URL?

    let uploader = ChunkUploader.shared
    let webViewStore = PersistentWebViewStore()
    private var stateAuditTimer: Timer?

    /// Called by WebView coordinator when recording starts (to notify the web page).
    var onRecordingStartedInWebView: ((String, Int64) -> Void)?

    init() {
        _ = SessionDiagnostics.shared
        listenForDarwinNotifications()
        uploader.onAllUploaded = { [weak self] in
            self?.broadcastStatus = "completed"
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.broadcastStatus == "recording" || self.broadcastStatus == "stopped" else { return }
                self.checkPendingState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stateAuditTimer = timer
        checkPendingState()
        if let testInterviewURL = RecorderConstants.testInterviewURL {
            RecorderLog.write("app", "temporary_test_launch_enabled", [
                "host": testInterviewURL.host ?? "unknown",
                "path": testInterviewURL.path
            ])
            handleDeepLink(testInterviewURL)
        }
    }

    // MARK: - Deep link handling

    func handleDeepLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let urlPath = components?.path ?? url.path
        let urlHost = components?.host ?? ""
        let routePath = normalizedRoutePath(
            scheme: components?.scheme ?? url.scheme,
            host: urlHost,
            path: urlPath
        )
        let routeKey = routePath.lowercased()

        print("[SessionManager] handleDeepLink: host=\(urlHost) path=\(routePath)")
        RecorderLog.write("app", "deep_link_received", [
            "scheme": components?.scheme ?? url.scheme ?? "unknown",
            "host": urlHost,
            "path": routePath
        ])

        if let returnURL = components?.queryItems?.first(where: { $0.name == "return" })?.value {
            let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
            defaults?.set(returnURL, forKey: RecorderConstants.returnURLKey)
            defaults?.synchronize()
        }


        persistRecoveryMetadata(from: components)

        switch routeKey {
        case _ where routeKey.contains("/session"):
            webViewURL = URL(string: "\(RecorderConstants.siteURL)/session/room")
            path = [.session]

        case _ where routeKey.contains("/interview"):
            guard let destination = webDestinationURL(
                from: url,
                components: components,
                routePath: routePath
            ) else {
                RecorderLog.write("app", "deep_link_rejected", [
                    "reason": "invalid_interview_destination",
                    "host": urlHost,
                    "path": routePath
                ])
                return
            }
            webViewURL = destination
            print("[SessionManager] interview WebView URL configured")
            path = [.session]

        case _ where routeKey.hasSuffix("/recording/start"):
            path = [.start]

        case _ where routeKey.hasSuffix("/recording/stop"):
            requestStop()
            path = [.stop]

        default:
            RecorderLog.write("app", "deep_link_unhandled", [
                "host": urlHost,
                "path": routePath
            ])
        }
    }

    /// Custom URL schemes place the first route component in the host:
    /// `satellica-recorder://interview` has host `interview` and an empty path.
    /// Normalize it to the same `/interview` shape used by Universal Links.
    private func normalizedRoutePath(scheme: String?, host: String, path: String) -> String {
        guard scheme?.lowercased() == RecorderConstants.customURLScheme,
              !host.isEmpty else { return path }

        let suffix: String
        if path.isEmpty || path == "/" {
            suffix = ""
        } else if path.hasPrefix("/") {
            suffix = path
        } else {
            suffix = "/\(path)"
        }
        return "/\(host)\(suffix)"
    }

    /// WKWebView can't load the app's custom scheme. Convert it to the active
    /// site's HTTPS origin while preserving the route, query, and fragment.
    private func webDestinationURL(
        from originalURL: URL,
        components: URLComponents?,
        routePath: String
    ) -> URL? {
        guard components?.scheme?.lowercased() == RecorderConstants.customURLScheme else {
            return originalURL
        }
        guard var destination = URLComponents(
            url: RecorderConstants.siteBaseURL,
            resolvingAgainstBaseURL: false
        ) else { return nil }

        destination.path = routePath.hasPrefix("/") ? routePath : "/\(routePath)"
        destination.queryItems = components?.queryItems
        destination.fragment = components?.fragment
        return destination.url
    }

    // MARK: - Recording control

    func triggerStart() {
        guard NativeUploadContextStore.load() != nil else {
            SessionDiagnostics.shared.record("recording_start_blocked missing_upload_context=true")
            return
        }
        SessionDiagnostics.shared.record("recording_start_requested")
        uploader.reset()
        broadcastStatus = "idle"

        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set(false, forKey: RecorderConstants.stopRequestedKey)
        defaults?.synchronize()

        BroadcastTriggerButton.trigger()
    }

    /// Validates and durably hands the web-issued recording credentials to the
    /// host app and ReplayKit extension before the system picker is opened.
    func configureNativeUpload(from body: [String: Any]) -> Bool {
        guard RecorderConstants.isAppGroupContainerAvailable else {
            SessionDiagnostics.shared.record("upload_context_invalid app_group_unavailable=true")
            return false
        }
        guard let recordingId = body["recordingId"] as? String,
              recordingId.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil,
              let uploadToken = body["uploadToken"] as? String, !uploadToken.isEmpty,
              let serverEpochMs = int64(body["serverEpochMs"]),
              let chunkSeconds = number(body["chunkSeconds"]), chunkSeconds > 0,
              let chunkURLBatch = int(body["chunkUrlBatch"]), (1...20).contains(chunkURLBatch),
              let maxChunkBytes = int64(body["maxChunkBytes"]), maxChunkBytes > 0 else {
            SessionDiagnostics.shared.record("upload_context_invalid")
            return false
        }

        // The current container layout intentionally supports one durable
        // recording at a time. Never let a second start erase chunks that have
        // not yet been accepted by /complete.
        if let existing = RecordingManifest.load(), existing.status != "completed" {
            SessionDiagnostics.shared.record(
                "upload_context_rejected unfinished_recording=true existing=\(existing.sessionId)"
            )
            return false
        }

        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        let interviewLink = (body["interviewLink"] as? String)
            ?? defaults?.string(forKey: RecorderConstants.interviewLinkKey)
        let studyId = (body["studyId"] as? String)
            ?? defaults?.string(forKey: RecorderConstants.studyIdKey)

        guard let interviewLink, !interviewLink.isEmpty,
              let studyId, !studyId.isEmpty else {
            SessionDiagnostics.shared.record("upload_context_missing_recovery_metadata")
            return false
        }

        let context = NativeUploadContext(
            environment: RecorderConstants.environment,
            recordingId: recordingId,
            uploadToken: uploadToken,
            serverEpochMs: serverEpochMs,
            chunkSeconds: chunkSeconds,
            chunkURLBatch: chunkURLBatch,
            maxChunks: int(body["maxChunks"]),
            maxChunkBytes: maxChunkBytes,
            apiOrigin: RecorderConstants.siteBaseURL,
            interviewLink: interviewLink,
            studyId: studyId,
            createdAt: Date(),
            startedAtDeviceEpochMs: nil
        )

        guard NativeUploadContextStore.save(context),
              let persistedContext = NativeUploadContextStore.load(),
              persistedContext.recordingId == context.recordingId,
              persistedContext.uploadToken == context.uploadToken,
              persistedContext.chunkSeconds == context.chunkSeconds,
              persistedContext.maxChunkBytes == context.maxChunkBytes else {
            SessionDiagnostics.shared.record("upload_context_persist_failed")
            return false
        }
        RecorderLog.write("app", "upload_context_saved", [
            "recordingId": recordingId,
            "environment": RecorderConstants.environment.rawValue,
            "chunkSeconds": chunkSeconds,
            "chunkUrlBatch": chunkURLBatch,
            "maxChunkBytes": maxChunkBytes,
            "hasInterviewLink": !interviewLink.isEmpty,
            "hasStudyId": !studyId.isEmpty
        ])
        return true
    }

    func requestStop(completed: Bool = true) {
        SessionDiagnostics.shared.record("recording_stop_requested completed=\(completed)")
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        if var context = NativeUploadContextStore.load() {
            context.siteCompleted = completed
            let saved = NativeUploadContextStore.save(context)
            let verified = NativeUploadContextStore.load()?.siteCompleted == completed
            SessionDiagnostics.shared.record(
                "recording_stop_mode_persisted completed=\(completed) saved=\(saved) verified=\(verified)"
            )
            defaults?.set(context.recordingId, forKey: RecorderConstants.siteStopRecordingIdKey)
        }
        // Independent fallback in case the context file is temporarily
        // unavailable during a process restart.
        defaults?.set(completed, forKey: RecorderConstants.siteStopCompletedKey)
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

    func handleScenePhase(_ phase: ScenePhase) {
        webViewStore.recordScenePhase(phase)
        if phase == .active {
            checkPendingState()
        }
    }

    func checkPendingState() {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        var manifest = RecordingManifest.load()
        let persistedStatus = defaults?.string(forKey: RecorderConstants.broadcastStatusKey) ?? "idle"
        var status = manifest?.status == "completed" ? "completed" : persistedStatus
        var recoveredStaleBroadcast = false

        if status == "recording", var recordingManifest = manifest,
           recordingManifest.status == "recording" {
            let heartbeatMs = Int64(defaults?.double(
                forKey: RecorderConstants.broadcastHeartbeatMsKey
            ) ?? 0)
            let nowMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            if heartbeatMs > 0, nowMs - heartbeatMs > 120_000 {
                recordingManifest.status = "stopped"
                recordingManifest.interruptedAtMs = nowMs
                recordingManifest.interruptedReason = "broadcastHeartbeatExpired"
                if recordingManifest.save(), RecordingManifest.load()?.status == "stopped" {
                    defaults?.set(true, forKey: RecorderConstants.stopRequestedKey)
                    defaults?.set("stopped", forKey: RecorderConstants.broadcastStatusKey)
                    defaults?.synchronize()
                    manifest = RecordingManifest.load()
                    status = "stopped"
                    recoveredStaleBroadcast = true
                    SessionDiagnostics.shared.record(
                        "broadcast_stale_heartbeat_recovered ageMs=\(nowMs - heartbeatMs)"
                    )
                } else {
                    SessionDiagnostics.shared.record("broadcast_stale_heartbeat_recovery_failed")
                }
            }
        }
        print("[SessionManager] checkPendingState: broadcastStatus=\(status)")

        isRecording = (status == "recording")

        broadcastStatus = status

        uploader.uploadPendingChunks()

        if status == "stopped" && (path.isEmpty || recoveredStaleBroadcast) && broadcastStatus != "completed" {
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
        stateAuditTimer?.invalidate()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    private func onBroadcastStarted() {
        print("[SessionManager] 🟢 broadcastStarted")
        SessionDiagnostics.shared.record("broadcast_started")
        uploader.reset()
        isRecording = true
        broadcastStatus = "recording"

        // Prevent screen from auto-locking during recording
        UIApplication.shared.isIdleTimerDisabled = true
        webViewStore.sampleMediaState(reason: "broadcast_started", force: true)
        CallAudioSessionManager.shared.logCurrentState(event: "audio_broadcast_started")

        if let context = NativeUploadContextStore.load(),
           let startedAtDeviceEpochMs = context.startedAtDeviceEpochMs {
            RecorderLog.write("app", "recording_started_event_ready", [
                "recordingId": context.recordingId,
                "startedAtDeviceEpochMs": startedAtDeviceEpochMs
            ])
            onRecordingStartedInWebView?(context.recordingId, startedAtDeviceEpochMs)
        } else {
            SessionDiagnostics.shared.record("recording_started_metadata_missing")
        }
        onRecordingStartedInWebView = nil
    }

    private func onBroadcastFinished() {
        print("[SessionManager] 🔴 broadcastFinished")
        SessionDiagnostics.shared.record("broadcast_finished")
        isRecording = false

        if broadcastStatus != "completed" {
            broadcastStatus = "stopped"
        }

        let manifest = RecordingManifest.load()
        print("[SessionManager] manifest chunks: \(manifest?.chunks.count ?? 0), status: \(manifest?.status ?? "nil")")

        uploader.uploadPendingChunks()

        if !path.contains(.stop) {
            path = [.stop]
        }
    }

    private func onChunkReady() {
        print("[SessionManager] 📦 chunkReady")
        let manifest = RecordingManifest.load()
        RecorderLog.write("app", "chunk_ready_notification", [
            "recordingId": manifest?.sessionId ?? "unknown",
            "chunkCount": manifest?.chunks.count ?? 0,
            "latestIndex": manifest?.chunks.map(\.index).max() ?? -1
        ])
        uploader.uploadPendingChunks()
    }

    func resetCompletedSession() {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set("idle", forKey: RecorderConstants.broadcastStatusKey)
        defaults?.removeObject(forKey: RecorderConstants.siteStopCompletedKey)
        defaults?.removeObject(forKey: RecorderConstants.siteStopRecordingIdKey)
        defaults?.synchronize()

        broadcastStatus = "idle"
        uploader.reset()
        RecordingManifest.clear()
        ChunkMetadataStore.clear()
        NativeUploadContextStore.clear()
        webViewStore.reset()
        CallAudioSessionManager.shared.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        path = []
        SessionDiagnostics.shared.record("session_reset_completed")
    }

    private func persistRecoveryMetadata(from components: URLComponents?) {
        guard let components else { return }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { values[item.name.lowercased()] = value }
        }
        let pathParts = components.path.split(separator: "/").map(String.init)
        let interviewPathValue = pathParts.firstIndex(of: "interview").flatMap { index in
            pathParts.indices.contains(index + 1) ? pathParts[index + 1] : nil
        }
        let interviewLink = values["interviewlink"]
            ?? values["interview_link"]
            ?? interviewPathValue
        let studyId = values["studyid"] ?? values["study_id"]
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        if let interviewLink, !interviewLink.isEmpty {
            defaults?.set(interviewLink, forKey: RecorderConstants.interviewLinkKey)
        }
        if let studyId, !studyId.isEmpty {
            defaults?.set(studyId, forKey: RecorderConstants.studyIdKey)
        }
        defaults?.synchronize()
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}
