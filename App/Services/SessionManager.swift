//  SessionManager.swift
//  SatellicaRecorder — recording session lifecycle, deep link handling,
//  Darwin notification listeners, WebView bridge, and state coordination.

import SwiftUI

struct SessionExitAlert: Identifiable {
    enum Action {
        case exitInterview
        case dismiss
    }

    let id = UUID()
    let title: String
    let message: String
    var buttonTitle: String = "Exit Interview"
    var action: Action = .exitInterview
}

private struct UploadEligibilityResponse: Decodable {
    let uploadable: [String]
    let alreadyUploaded: [String]
}

@MainActor
final class SessionManager: ObservableObject {
    @Published var path: [AppRoute] = []
    @Published var isRecording = false
    @Published var broadcastStatus: String = "idle"  // idle, recording, stopped, completed
    @Published var sessionExitAlert: SessionExitAlert?
    @Published private(set) var navigationGeneration = 0
    @Published var webViewLoadFailed = false

    /// The URL to load in the WebView (set by deep link handler).
    @Published var webViewURL: URL?

    let uploader = ChunkUploader.shared
    let webViewStore = PersistentWebViewStore()
    private var stateAuditTimer: Timer?
    private var isCheckingEligibility = false
    private var eligibilityRetryWorkItem: DispatchWorkItem?
    private var isAwaitingBroadcastStart = false

    /// Called by WebView coordinator when recording starts (to notify the web page).
    var onRecordingStartedInWebView: ((String, Int64) -> Void)?

    init() {
        _ = SessionDiagnostics.shared
        RecordingStore.prepare()
        listenForDarwinNotifications()
        uploader.cancelUnauthorizedBackgroundTasks()
        uploader.onAllUploaded = { [weak self] in
            self?.finishCurrentUpload()
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
        if !UploadQueueStore.all().isEmpty || uploader.isUploading {
            abandonUnstartedRecordingAttempt()
            SessionDiagnostics.shared.record("deep_link_blocked upload_queue_active=true")
            path = [.stop]
            processUploadQueueIfPossible()
            return
        }
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
            guard WebSecurityPolicy.isTrusted(destination) else {
                RecorderLog.write("app", "deep_link_rejected", [
                    "reason": "untrusted_interview_origin",
                    "host": destination.host ?? "unknown",
                    "path": destination.path
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

        abandonUnstartedRecordingAttempt()
        guard UploadQueueStore.all().isEmpty, !uploader.isUploading, !isRecording else {
            SessionDiagnostics.shared.record("upload_context_rejected recording_or_upload_active=true")
            processUploadQueueIfPossible()
            return false
        }
        guard availableDiskBytes() >= RecorderConstants.minFreeDiskToStart else {
            SessionDiagnostics.shared.record("upload_context_rejected insufficient_start_disk=true")
            sessionExitAlert = SessionExitAlert(
                title: "Not enough storage",
                message: "At least 700 MB of free storage is required to start recording. " +
                    "Free up some space and try again.",
                buttonTitle: "OK",
                action: .dismiss
            )
            return false
        }
        RecordingStore.prepare()
        for staleId in RecordingStore.recordingIds() where
            RecordingManifestStore.load(recordingId: staleId) == nil &&
            NativeUploadContextStore.load(recordingId: staleId)?.startedAtDeviceEpochMs == nil {
            RecordingStore.delete(recordingId: staleId)
        }
        if RecordingStore.recordingIds().contains(recordingId) {
            SessionDiagnostics.shared.record(
                "upload_context_rejected retained_recording_exists=true existing=\(recordingId)"
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
            startedAtDeviceEpochMs: nil,
            siteCompleted: nil,
            sessionStarted: false,
            uploadAuthorized: false,
            stopRequestedBySite: false,
            stopRequestedAtDeviceEpochMs: nil
        )

        RecordingStore.setActiveRecordingId(recordingId)
        guard NativeUploadContextStore.save(context),
              let persistedContext = NativeUploadContextStore.load(),
              persistedContext.recordingId == context.recordingId,
              persistedContext.uploadToken == context.uploadToken,
              persistedContext.chunkSeconds == context.chunkSeconds,
              persistedContext.maxChunkBytes == context.maxChunkBytes else {
            SessionDiagnostics.shared.record("upload_context_persist_failed")
            RecordingStore.delete(recordingId: recordingId)
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
        isAwaitingBroadcastStart = true
        return true
    }

    func markSessionStarted() -> Bool {
        guard isRecording, var context = NativeUploadContextStore.load() else { return false }
        context.sessionStarted = true
        let saved = NativeUploadContextStore.save(context)
        SessionDiagnostics.shared.record(
            "site_session_started recordingId=\(context.recordingId) saved=\(saved)"
        )
        return saved
    }

    func requestStop(completed: Bool = false) {
        SessionDiagnostics.shared.record("recording_stop_requested completed=\(completed)")
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        var persistedCompleted = completed
        if var context = NativeUploadContextStore.load() {
            // Upload authorization is sticky. A duplicate late `false` message
            // can never undo a previously persisted `complete: true` decision.
            let effectiveCompleted = context.uploadAuthorized == true || completed
            persistedCompleted = effectiveCompleted
            context.siteCompleted = effectiveCompleted
            context.uploadAuthorized = effectiveCompleted
            context.stopRequestedBySite = true
            context.stopRequestedAtDeviceEpochMs = nowDeviceEpochMs()
            let saved = NativeUploadContextStore.save(context)
            let verified = NativeUploadContextStore.load()?.uploadAuthorized == effectiveCompleted
            SessionDiagnostics.shared.record(
                "recording_stop_mode_persisted completed=\(effectiveCompleted) saved=\(saved) verified=\(verified)"
            )
            if effectiveCompleted {
                UploadQueueStore.enqueue(context.recordingId)
                webViewStore.reset()
                CallAudioSessionManager.shared.deactivate()
                path = [.stop]
            }
            defaults?.set(context.recordingId, forKey: RecorderConstants.siteStopRecordingIdKey)
        }
        // Independent fallback in case the context file is temporarily
        // unavailable during a process restart.
        defaults?.set(persistedCompleted, forKey: RecorderConstants.siteStopCompletedKey)
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
        RecordingStore.prepare()
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        let manifest = RecordingManifest.load()
        let persistedStatus = defaults?.string(forKey: RecorderConstants.broadcastStatusKey) ?? "idle"
        let status = manifest?.status == "completed" ? "completed" : persistedStatus
        print("[SessionManager] checkPendingState: broadcastStatus=\(status)")

        isRecording = (status == "recording")
        broadcastStatus = status
        if !isRecording, !UploadQueueStore.all().isEmpty {
            processUploadQueueIfPossible()
        } else if status == "stopped", UploadQueueStore.all().isEmpty {
            // A retained, incomplete session belongs on Home after a relaunch.
            RecordingStore.setActiveRecordingId(nil)
            broadcastStatus = "idle"
            defaults?.set("idle", forKey: RecorderConstants.broadcastStatusKey)
            defaults?.synchronize()
        }
        Task { await checkUploadEligibility() }
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

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            let mgr = Unmanaged<SessionManager>.fromOpaque(obs).takeUnretainedValue()
            Task { @MainActor in mgr.onBroadcastFailed() }
        }, RecorderConstants.broadcastFailedNotification, nil, .deliverImmediately)
    }

    deinit {
        stateAuditTimer?.invalidate()
        eligibilityRetryWorkItem?.cancel()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    private func onBroadcastStarted() {
        print("[SessionManager] 🟢 broadcastStarted")
        SessionDiagnostics.shared.record("broadcast_started")
        uploader.reset()
        isAwaitingBroadcastStart = false
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

        broadcastStatus = "stopped"

        let stoppedManifest = RecordingManifest.load()
        print("[SessionManager] manifest chunks: \(stoppedManifest?.chunks.count ?? 0), status: \(stoppedManifest?.status ?? "nil")")

        guard let recordingId = RecorderConstants.activeRecordingId else {
            SessionDiagnostics.shared.record("broadcast_finished_missing_recording_id")
            presentStoppedSessionAlert(SessionExitAlert(
                title: "Session interrupted",
                message: "Screen recording stopped, so this session can’t continue."
            ))
            return
        }
        guard let context = NativeUploadContextStore.load(recordingId: recordingId) else {
            SessionDiagnostics.shared.record(
                "broadcast_finished_upload_context_unavailable recordingId=\(recordingId)"
            )
            presentStoppedSessionAlert(SessionExitAlert(
                title: "Session interrupted",
                message: "Screen recording stopped, so this session can’t continue. " +
                    "Your recording has been saved safely on this device."
            ))
            return
        }

        if context.uploadAuthorized == true {
            path = [.stop]
            processUploadQueueIfPossible()
            return
        }

        let manifest = RecordingManifestStore.load(recordingId: recordingId)
        let atMs = manifest?.interruptedAtMs ?? context.stopRequestedAtDeviceEpochMs ?? nowDeviceEpochMs()
        if context.sessionStarted == true {
            let alert = SessionExitAlert(
                title: context.stopRequestedBySite == true ? "Session ended" : "Session interrupted",
                message: context.stopRequestedBySite == true
                    ? "This session ended before completion. Your recording has been saved safely on this device."
                    : "Screen recording stopped, so this session can’t continue. Your recording has been saved safely on this device."
            )
            let returnHome: () -> Void = { [weak self] in
                guard let self else { return }
                self.presentStoppedSessionAlert(alert)
            }
            if context.stopRequestedBySite == true {
                dispatchWebEvent("recordingStopped", completion: returnHome)
            } else {
                dispatchWebEvent("recordingInterrupted", detail: [
                    "reason": webInterruptionReason(manifest?.interruptedReason),
                    "atDeviceEpochMs": atMs
                ], completion: returnHome)
            }
        } else {
            if context.stopRequestedBySite == true {
                dispatchWebEvent("recordingStopped")
            } else {
                dispatchWebEvent("recordingInterrupted", detail: [
                    "reason": webInterruptionReason(manifest?.interruptedReason),
                    "atDeviceEpochMs": atMs
                ])
            }
            RecordingStore.delete(recordingId: recordingId)
            resetSharedBroadcastFlags()
            broadcastStatus = "idle"
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
        // Chunks remain local until `complete: true` or backend eligibility.
    }

    private func onBroadcastFailed() {
        guard !isRecording, let recordingId = RecorderConstants.activeRecordingId else { return }
        isAwaitingBroadcastStart = false
        dispatchWebEvent("recordingFailed", detail: ["reason": "startFailed"])
        RecordingStore.delete(recordingId: recordingId)
        resetSharedBroadcastFlags()
        broadcastStatus = "idle"
        SessionDiagnostics.shared.record("broadcast_start_failed")
    }

    func leaveInterruptedSession() {
        sessionExitAlert = nil
        RecordingStore.setActiveRecordingId(nil)
        resetSharedBroadcastFlags()
        broadcastStatus = "idle"
        forceNavigationHome()
        webViewStore.reset()
        webViewURL = nil
        CallAudioSessionManager.shared.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        processUploadQueueIfPossible()
        Task { await checkUploadEligibility() }
    }

    func handleAlertAction(_ action: SessionExitAlert.Action) {
        switch action {
        case .exitInterview:
            leaveInterruptedSession()
        case .dismiss:
            sessionExitAlert = nil
        }
    }

    /// Explicitly leaving the Site is the lifecycle boundary for its media
    /// context. The WKWebView remains persistent while a Site session is on
    /// screen, but it must not keep WebRTC tracks alive behind the App Home.
    func returnHomeFromWebSession() {
        guard !isRecording else {
            SessionDiagnostics.shared.record("web_session_exit_blocked recording=true")
            return
        }
        abandonUnstartedRecordingAttempt()
        webViewStore.reset()
        webViewURL = nil
        CallAudioSessionManager.shared.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        path = []
        SessionDiagnostics.shared.record("web_session_exited_to_home")
    }

    func retryWebViewLoad() {
        webViewStore.retryCurrentPage()
    }

    private func processUploadQueueIfPossible() {
        guard !isRecording, !isAwaitingBroadcastStart, sessionExitAlert == nil,
              let recordingId = UploadQueueStore.all().first else { return }
        guard NativeUploadContextStore.load(recordingId: recordingId)?.uploadAuthorized == true else {
            UploadQueueStore.remove(recordingId)
            processUploadQueueIfPossible()
            return
        }
        if RecorderConstants.activeRecordingId != recordingId {
            uploader.reset()
            RecordingStore.setActiveRecordingId(recordingId)
        }
        if path.contains(.session) {
            webViewStore.reset()
            webViewURL = nil
            CallAudioSessionManager.shared.deactivate()
        }
        path = [.stop]
        uploader.uploadPendingChunks()
    }

    private func finishCurrentUpload() {
        guard let recordingId = RecorderConstants.activeRecordingId else { return }
        let deleted = RecordingStore.delete(recordingId: recordingId)
        if !deleted { scheduleEligibilityRetry() }
        UIApplication.shared.isIdleTimerDisabled = false
        if UploadQueueStore.all().isEmpty {
            broadcastStatus = "completed"
        } else {
            broadcastStatus = "stopped"
            uploader.reset()
            processUploadQueueIfPossible()
        }
    }

    private func checkUploadEligibility() async {
        guard !isCheckingEligibility else { return }
        let activeId = isRecording ? RecorderConstants.activeRecordingId : nil
        let ids = RecordingStore.recordingIds().filter { recordingId in
            guard recordingId != activeId,
                  let status = RecordingManifestStore.load(recordingId: recordingId)?.status else {
                return false
            }
            return status == "stopped" || status == "completed"
        }
        guard !ids.isEmpty else {
            eligibilityRetryWorkItem?.cancel()
            eligibilityRetryWorkItem = nil
            return
        }
        eligibilityRetryWorkItem?.cancel()
        eligibilityRetryWorkItem = nil
        isCheckingEligibility = true
        defer { isCheckingEligibility = false }
        var shouldRetry = false
        var hasUnresolvedUploadable = false
        var hasMissingUploadContext = false

        for start in stride(from: 0, to: ids.count, by: 100) {
            let requested = Array(ids[start..<min(start + 100, ids.count)])
            let requestStartedAt = Date()
            RecorderLog.write("app", "upload_eligibility_request", [
                "batchStart": start,
                "recordingCount": requested.count,
                "method": "POST",
                "endpointPath": "/api/recordings/upload-eligibility"
            ])
            do {
                let endpoint = RecorderConstants.siteBaseURL
                    .appendingPathComponent("api")
                    .appendingPathComponent("recordings")
                    .appendingPathComponent("upload-eligibility")
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["recordingIds": requested])
                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                let status = httpResponse?.statusCode ?? 0
                RecorderLog.write("app", "upload_eligibility_response", [
                    "batchStart": start,
                    "recordingCount": requested.count,
                    "status": status,
                    "elapsedMs": Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                    "responseBytes": data.count,
                    "contentType": httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                ])
                guard status == 200 else {
                    shouldRetry = true
                    continue
                }
                let result = try JSONDecoder().decode(UploadEligibilityResponse.self, from: data)
                let requestedSet = Set(requested)
                let uploadable = Set(result.uploadable)
                let alreadyUploaded = Set(result.alreadyUploaded)
                guard uploadable.isSubset(of: requestedSet),
                      alreadyUploaded.isSubset(of: requestedSet),
                      uploadable.isDisjoint(with: alreadyUploaded) else {
                    RecorderLog.write("app", "upload_eligibility_invalid_response", [
                        "requestedCount": requested.count,
                        "uploadableCount": uploadable.count,
                        "alreadyUploadedCount": alreadyUploaded.count
                    ])
                    shouldRetry = true
                    continue
                }
                RecorderLog.write("app", "upload_eligibility_result", [
                    "requestedCount": requested.count,
                    "uploadableCount": uploadable.count,
                    "alreadyUploadedCount": alreadyUploaded.count,
                    "pendingCount": requestedSet.subtracting(uploadable).subtracting(alreadyUploaded).count
                ])
                for recordingId in alreadyUploaded {
                    uploader.cancelBackgroundTasks(recordingId: recordingId)
                    if RecorderConstants.activeRecordingId == recordingId {
                        uploader.reset()
                    }
                    let deleted = RecordingStore.delete(recordingId: recordingId)
                    RecorderLog.write("app", "eligibility_already_uploaded_cleanup", [
                        "recordingId": recordingId,
                        "localRecordingDeleted": deleted
                    ])
                    if !deleted {
                        shouldRetry = true
                    }
                }
                for recordingId in uploadable {
                    guard var context = NativeUploadContextStore.load(recordingId: recordingId) else {
                        hasUnresolvedUploadable = true
                        let contextExists = FileManager.default.fileExists(
                            atPath: RecorderConstants.uploadContextURL(for: recordingId).path
                        )
                        SessionDiagnostics.shared.record(
                            "upload_eligibility_context_unavailable recordingId=\(recordingId) " +
                            "fileExists=\(contextExists)"
                        )
                        // A protected or temporarily unreadable file may become
                        // available without user intervention. A truly missing
                        // token cannot be reconstructed by this endpoint, so it
                        // is retried on the next normal app state audit instead
                        // of creating a permanent 30-second network loop.
                        if contextExists {
                            shouldRetry = true
                        } else {
                            hasMissingUploadContext = true
                        }
                        continue
                    }
                    context.uploadAuthorized = true
                    context.siteCompleted = true
                    guard NativeUploadContextStore.save(context),
                          NativeUploadContextStore.load(recordingId: recordingId)?.uploadAuthorized == true else {
                        shouldRetry = true
                        hasUnresolvedUploadable = true
                        SessionDiagnostics.shared.record(
                            "upload_eligibility_authorization_persist_failed recordingId=\(recordingId)"
                        )
                        continue
                    }
                    UploadQueueStore.enqueue(recordingId)
                    RecorderLog.write("app", "eligibility_upload_authorized", [
                        "recordingId": recordingId,
                        "contextPersisted": true,
                        "queued": UploadQueueStore.all().contains(recordingId)
                    ])
                }
            } catch {
                shouldRetry = true
                let nsError = error as NSError
                RecorderLog.write("app", "upload_eligibility_transport_or_decode_error", [
                    "batchStart": start,
                    "recordingCount": requested.count,
                    "elapsedMs": Int(Date().timeIntervalSince(requestStartedAt) * 1_000),
                    "errorDomain": nsError.domain,
                    "errorCode": nsError.code,
                    "errorDescription": error.localizedDescription
                ])
            }
        }
        processUploadQueueIfPossible()
        if hasMissingUploadContext, UploadQueueStore.all().isEmpty,
           !uploader.isUploading, !isRecording {
            if path == [.stop] { path = [] }
            broadcastStatus = "idle"
        } else if UploadQueueStore.all().isEmpty, path == [.stop], !isRecording,
           !hasUnresolvedUploadable {
            broadcastStatus = "completed"
        } else if hasUnresolvedUploadable, !isRecording {
            broadcastStatus = "stopped"
        }
        if shouldRetry { scheduleEligibilityRetry() }
    }

    private func scheduleEligibilityRetry() {
        guard eligibilityRetryWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.eligibilityRetryWorkItem = nil
            Task { await self.checkUploadEligibility() }
        }
        eligibilityRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func dispatchWebEvent(
        _ name: String,
        detail: [String: Any]? = nil,
        completion: (() -> Void)? = nil
    ) {
        webViewStore.dispatchEvent(name, detail: detail, completion: completion)
    }

    private func presentStoppedSessionAlert(_ alert: SessionExitAlert) {
        sessionExitAlert = alert
        SessionDiagnostics.shared.record("stopped_session_alert_presented")
        Task { await checkUploadEligibility() }
    }

    private func forceNavigationHome() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path.removeAll()
            navigationGeneration &+= 1
        }
        SessionDiagnostics.shared.record("navigation_forced_home")
    }

    private func abandonUnstartedRecordingAttempt() {
        guard isAwaitingBroadcastStart,
              let pendingId = RecorderConstants.activeRecordingId,
              RecordingManifestStore.load(recordingId: pendingId) == nil else { return }
        RecordingStore.delete(recordingId: pendingId)
        isAwaitingBroadcastStart = false
    }

    private func webInterruptionReason(_ raw: String?) -> String {
        switch raw {
        case "insufficientDisk": return "insufficientDisk"
        case "rotatedWriterStartFailed", "encoderFailure": return "encoderFailure"
        case "systemBroadcastFinished": return "userStopped"
        case nil: return "unknown"
        default: return "broadcastTerminated"
        }
    }

    private func nowDeviceEpochMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private func availableDiskBytes() -> Int64 {
        guard let values = try? RecorderConstants.containerURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return Int64.max }
        return values.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    private func resetSharedBroadcastFlags() {
        let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
        defaults?.set(false, forKey: RecorderConstants.stopRequestedKey)
        defaults?.set("idle", forKey: RecorderConstants.broadcastStatusKey)
        defaults?.removeObject(forKey: RecorderConstants.siteStopCompletedKey)
        defaults?.removeObject(forKey: RecorderConstants.siteStopRecordingIdKey)
        defaults?.synchronize()
    }

    func resetCompletedSession() {
        resetSharedBroadcastFlags()
        broadcastStatus = "idle"
        uploader.reset()
        RecordingStore.setActiveRecordingId(nil)
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
