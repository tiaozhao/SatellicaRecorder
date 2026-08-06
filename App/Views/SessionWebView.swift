//  SessionWebView.swift
//  One long-lived WKWebView for the complete LiveKit/recording session.

import SwiftUI
import WebKit

/// Central allow-list for every privileged WebView capability. The bridge,
/// media capture, and in-WebView navigation must all agree on the same origin.
enum WebSecurityPolicy {
    static func isTrusted(_ url: URL?) -> Bool {
        guard let url,
              let scheme = normalized(url.scheme),
              let host = normalizedHost(url.host),
              let trustedScheme = normalized(RecorderConstants.siteBaseURL.scheme),
              let trustedHost = normalizedHost(RecorderConstants.siteBaseURL.host) else {
            return false
        }

        return scheme == trustedScheme &&
            host == trustedHost &&
            normalizedPort(url.port, scheme: scheme) == normalizedPort(
                RecorderConstants.siteBaseURL.port,
                scheme: trustedScheme
            )
    }

    static func isTrusted(_ origin: WKSecurityOrigin) -> Bool {
        guard let scheme = normalized(origin.protocol),
              let host = normalizedHost(origin.host),
              let trustedScheme = normalized(RecorderConstants.siteBaseURL.scheme),
              let trustedHost = normalizedHost(RecorderConstants.siteBaseURL.host) else {
            return false
        }

        return scheme == trustedScheme &&
            host == trustedHost &&
            normalizedPort(origin.port, scheme: scheme) == normalizedPort(
                RecorderConstants.siteBaseURL.port,
                scheme: trustedScheme
            )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.lowercased()
    }

    private static func normalizedHost(_ value: String?) -> String? {
        guard var value = normalized(value) else { return nil }
        while value.hasSuffix(".") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    private static func normalizedPort(_ port: Int?, scheme: String) -> Int {
        if let port, port > 0 { return port }
        return scheme == "https" ? 443 : (scheme == "http" ? 80 : -1)
    }
}

/// Diagnostics only need the navigation destination, never query credentials.
private func diagnosticURL(_ url: URL?) -> String {
    guard let url else { return "nil" }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.fragment = nil
    return components?.url?.absoluteString ?? "redacted"
}

// MARK: - Full-screen page wrapper

struct SessionWebViewPage: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        ZStack {
            SessionWebView()
                .ignoresSafeArea()

            if session.webViewLoadFailed {
                WebViewFailureView {
                    session.retryWebViewLoad()
                }
                .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
    }
}

private struct WebViewFailureView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            STheme.shellGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(STheme.primary)
                    .frame(width: 80, height: 80)
                    .background(STheme.primary.opacity(0.1))
                    .clipShape(Circle())

                Text("Unable to load the interview")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(STheme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)

                Text("Check your internet connection and try again.")
                    .font(.system(size: 15))
                    .foregroundStyle(STheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 12)

                SButton(title: "Try Again", icon: "arrow.clockwise", action: retry)
                    .padding(.top, 32)
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 28)
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private final class WebEventCompletion {
    private var completion: (() -> Void)?

    init(_ completion: (() -> Void)?) {
        self.completion = completion
    }

    @discardableResult
    func finish() -> Bool {
        guard let completion else { return false }
        self.completion = nil
        completion()
        return true
    }
}

// MARK: - Persistent WebView owner

@MainActor
final class PersistentWebViewStore: ObservableObject {
    private(set) var webView: WKWebView?

    private var coordinator: SessionWebViewCoordinator?
    private var loadedEntryURL: URL?
    private var monitorTimer: Timer?
    private var monitorTick = 0
    private var lastCameraState: WKMediaCaptureState?
    private var lastMicrophoneState: WKMediaCaptureState?
    private var terminationCount = 0
    private var lastTerminationAt: Date?

    func makeOrReuseWebView(session: SessionManager) -> WKWebView {
        if let webView {
            coordinator?.session = session
            update(session: session)
            return webView
        }

        CallAudioSessionManager.shared.prepareForWebCall()

        let handler = SessionWebViewCoordinator()
        handler.session = session
        handler.store = self

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        config.userContentController.add(handler, name: "recorder")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = handler
        webView.navigationDelegate = handler
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // UIRefreshControl otherwise cannot be pulled when the website is
        // shorter than the visible WebView viewport.
        webView.scrollView.alwaysBounceVertical = true

        let refreshControl = UIRefreshControl()
        refreshControl.tintColor = .systemGray
        refreshControl.addTarget(
            handler,
            action: #selector(SessionWebViewCoordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        webView.customUserAgent = (webView.value(forKey: "userAgent") as? String ?? "") +
            " SatellicaApp/\(appVersion)"

        handler.webView = webView
        self.webView = webView
        coordinator = handler
        startMonitoring()

        SessionDiagnostics.shared.record("webview_created")
        update(session: session)
        return webView
    }

    func update(session: SessionManager) {
        guard let webView else { return }
        coordinator?.session = session
        webView.scrollView.refreshControl?.isEnabled = webView.microphoneCaptureState == .none
        webView.allowsBackForwardNavigationGestures = !session.isRecording

        let desiredURL = session.webViewURL ?? URL(string: "\(RecorderConstants.siteURL)/session/room")!
        guard WebSecurityPolicy.isTrusted(desiredURL) else {
            SessionDiagnostics.shared.record(
                "webview_entry_blocked_untrusted_origin url=\(diagnosticURL(desiredURL))"
            )
            return
        }
        guard loadedEntryURL != desiredURL else { return }

        // A new entry URL means a deliberately new study/session. Never
        // navigate the existing page merely because SwiftUI refreshed it.
        loadedEntryURL = desiredURL
        SessionDiagnostics.shared.record("webview_load_entry url=\(diagnosticURL(desiredURL))")
        webView.load(URLRequest(url: desiredURL))
    }

    func retryCurrentPage() {
        guard let webView else { return }
        let retryURL = WebSecurityPolicy.isTrusted(webView.url) ? webView.url : loadedEntryURL
        guard let retryURL, WebSecurityPolicy.isTrusted(retryURL) else {
            coordinator?.session?.webViewLoadFailed = true
            SessionDiagnostics.shared.record("webview_retry_blocked missing_trusted_url=true")
            return
        }
        SessionDiagnostics.shared.record("webview_retry url=\(diagnosticURL(retryURL))")
        webView.stopLoading()
        webView.load(URLRequest(
            url: retryURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        ))
    }

    func recordScenePhase(_ phase: ScenePhase) {
        SessionDiagnostics.shared.record("scene_phase value=\(String(describing: phase))")
        sampleMediaState(reason: "scene_\(String(describing: phase))", force: true)
        CallAudioSessionManager.shared.logCurrentState(
            event: "audio_scene_\(String(describing: phase))"
        )
    }

    func handleWebContentTermination(_ terminatedWebView: WKWebView) {
        guard terminatedWebView === webView else { return }

        let now = Date()
        if let lastTerminationAt, now.timeIntervalSince(lastTerminationAt) < 120 {
            terminationCount += 1
        } else {
            terminationCount = 1
        }
        lastTerminationAt = now

        SessionDiagnostics.shared.record(
            "webcontent_terminated count=\(terminationCount) url=\(diagnosticURL(terminatedWebView.url))"
        )

        // The old LiveKit in-memory connection is already gone. Reloading is
        // the only recovery available without changing website code/call state.
        guard terminationCount <= 3 else {
            SessionDiagnostics.shared.record("webcontent_reload_suppressed repeated_termination=true")
            return
        }

        let delay = min(Double(terminationCount), 3.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak terminatedWebView] in
            guard let self, let terminatedWebView, terminatedWebView === self.webView else { return }
            SessionDiagnostics.shared.record("webcontent_reload_attempt count=\(self.terminationCount)")
            if terminatedWebView.url != nil {
                terminatedWebView.reload()
            } else if let loadedEntryURL = self.loadedEntryURL {
                terminatedWebView.load(URLRequest(url: loadedEntryURL))
            }
        }
    }

    func sampleMediaState(reason: String, force: Bool = false) {
        guard let webView else { return }
        let camera = webView.cameraCaptureState
        let microphone = webView.microphoneCaptureState
        let changed = camera != lastCameraState || microphone != lastMicrophoneState
        webView.scrollView.refreshControl?.isEnabled = microphone == .none

        if force || changed {
            SessionDiagnostics.shared.record(
                "web_media_state reason=\(reason) camera=\(stateName(camera)) " +
                "microphone=\(stateName(microphone))"
            )
        }

        lastCameraState = camera
        lastMicrophoneState = microphone
    }

    func dispatchEvent(
        _ name: String,
        detail: [String: Any]? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let webView,
              ["recordingStarted", "recordingStopped", "recordingInterrupted", "recordingFailed"]
                .contains(name) else {
            completion?()
            return
        }
        let detailExpression: String
        if let detail,
           JSONSerialization.isValidJSONObject(detail),
           let data = try? JSONSerialization.data(withJSONObject: detail),
           let json = String(data: data, encoding: .utf8) {
            detailExpression = ", { detail: \(json) }"
        } else {
            detailExpression = ""
        }
        let script = "window.dispatchEvent(new CustomEvent('\(name)'\(detailExpression)))"
        let completionGate = WebEventCompletion(completion)
        if completion != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if completionGate.finish() {
                    SessionDiagnostics.shared.record("web_event_dispatch_timeout name=\(name)")
                }
            }
        }
        Task { @MainActor in
            defer { completionGate.finish() }
            do {
                _ = try await webView.evaluateJavaScript(script)
                SessionDiagnostics.shared.record("web_event_dispatched name=\(name)")
            } catch {
                SessionDiagnostics.shared.record(
                    "web_event_dispatch_failed name=\(name) error=\(error.localizedDescription)"
                )
            }
        }
    }

    func reset() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "recorder")
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            // Replacing the document tears down WebRTC MediaStream tracks
            // immediately, even if SwiftUI retains the UIView briefly during
            // the navigation transition back to Home.
            webView.loadHTMLString("", baseURL: nil)
        }
        coordinator?.session?.webViewLoadFailed = false
        coordinator = nil
        webView = nil
        loadedEntryURL = nil
        lastCameraState = nil
        lastMicrophoneState = nil
        SessionDiagnostics.shared.record("webview_reset")
    }

    private func startMonitoring() {
        monitorTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.monitorTick += 1
                self.sampleMediaState(
                    reason: "periodic",
                    force: self.monitorTick % 12 == 0
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    private func stateName(_ state: WKMediaCaptureState) -> String {
        switch state {
        case .active: return "active"
        case .muted: return "muted"
        case .none: return "none"
        @unknown default: return "unknown_\(state.rawValue)"
        }
    }
}

// MARK: - WKWebView representable

struct SessionWebView: UIViewRepresentable {
    @EnvironmentObject private var session: SessionManager

    func makeUIView(context: Context) -> WKWebView {
        session.webViewStore.makeOrReuseWebView(session: session)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        session.webViewStore.update(session: session)
    }
}

// MARK: - WebView delegates and JS bridge

final class SessionWebViewCoordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    weak var webView: WKWebView?
    weak var session: SessionManager?
    weak var store: PersistentWebViewStore?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            SessionDiagnostics.shared.record("web_bridge_invalid_message")
            return
        }
        guard message.frameInfo.isMainFrame,
              WebSecurityPolicy.isTrusted(message.frameInfo.securityOrigin) else {
            SessionDiagnostics.shared.record(
                "web_bridge_blocked_untrusted_origin origin=" +
                "\(message.frameInfo.securityOrigin.protocol)://" +
                "\(message.frameInfo.securityOrigin.host):" +
                "\(message.frameInfo.securityOrigin.port) mainFrame=\(message.frameInfo.isMainFrame)"
            )
            return
        }
        print("[WebView Bridge] received action: \(action)")

        Task { @MainActor in
            switch action {
            case "startRecording":
                SessionDiagnostics.shared.record("web_bridge_start_recording")
                RecorderLog.write("app", "web_start_message", [
                    "recordingId": body["recordingId"] as? String ?? "missing",
                    "hasUploadToken": (body["uploadToken"] as? String)?.isEmpty == false,
                    "hasServerEpochMs": body["serverEpochMs"] != nil,
                    "hasChunkSeconds": body["chunkSeconds"] != nil,
                    "hasChunkUrlBatch": body["chunkUrlBatch"] != nil,
                    "hasMaxChunkBytes": body["maxChunkBytes"] != nil
                ])
                guard self.session?.configureNativeUpload(from: body) == true else {
                    SessionDiagnostics.shared.record("web_bridge_start_rejected invalid_upload_context=true")
                    self.session?.webViewStore.dispatchEvent(
                        "recordingFailed",
                        detail: ["reason": "requestRejected"]
                    )
                    return
                }
                self.session?.onRecordingStartedInWebView = { [weak self] recordingId, startedAtDeviceEpochMs in
                    guard let webView = self?.webView else { return }
                    Task { @MainActor in
                        guard let recordingIdJSON = Self.jsonString(recordingId) else { return }
                        do {
                            _ = try await webView.evaluateJavaScript(
                                "window.dispatchEvent(new CustomEvent('recordingStarted', { detail: { " +
                                "recordingId: \(recordingIdJSON), " +
                                "startedAtDeviceEpochMs: \(startedAtDeviceEpochMs) } }))"
                            )
                            RecorderLog.write("app", "recording_started_event_dispatched", [
                                "recordingId": recordingId,
                                "startedAtDeviceEpochMs": startedAtDeviceEpochMs
                            ])
                        } catch {
                            SessionDiagnostics.shared.record(
                                "recording_started_event_failed error=\(error.localizedDescription)"
                            )
                        }
                    }
                }
                self.session?.triggerStart()

            case "startSession":
                SessionDiagnostics.shared.record("web_bridge_start_session")
                guard self.session?.markSessionStarted() == true else {
                    SessionDiagnostics.shared.record("web_bridge_start_session_rejected")
                    return
                }

            case "stopRecording":
                // Accept the current `completed` spelling and the concise
                // `complete` spelling used by newer site payloads.
                let completed = (body["completed"] as? Bool) ??
                    (body["complete"] as? Bool) ?? false
                SessionDiagnostics.shared.record(
                    "web_bridge_stop_recording completed=\(completed) " +
                    "fieldPresent=\(body["completed"] != nil || body["complete"] != nil)"
                )
                self.session?.requestStop(completed: completed)

            default:
                SessionDiagnostics.shared.record("web_bridge_unknown_action action=\(action)")
            }
        }
    }

    @objc func handleRefresh(_ sender: UIRefreshControl) {
        guard let webView else {
            sender.endRefreshing()
            return
        }
        guard webView.microphoneCaptureState == .none else {
            sender.endRefreshing()
            SessionDiagnostics.shared.record(
                "webview_refresh_blocked microphoneState=\(webView.microphoneCaptureState.rawValue)"
            )
            return
        }
        SessionDiagnostics.shared.record(
            "webview_pull_to_refresh recording=\(session?.isRecording == true)"
        )
        webView.reloadFromOrigin()
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard WebSecurityPolicy.isTrusted(origin) else {
            SessionDiagnostics.shared.record(
                "web_media_permission_denied_untrusted_origin origin=" +
                "\(origin.protocol)://\(origin.host):\(origin.port) " +
                "type=\(String(describing: type))"
            )
            decisionHandler(.deny)
            return
        }

        SessionDiagnostics.shared.record(
            "web_media_permission_granted origin=\(origin.protocol)://\(origin.host):\(origin.port) " +
            "type=\(String(describing: type))"
        )
        decisionHandler(.grant)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Never ask WKWebView or Safari to load our custom URL scheme. Route it
        // directly through the existing app-level deep-link handler instead.
        if handleAppDeepLink(navigationAction.request.url) {
            decisionHandler(.cancel)
            return
        }

        guard let destination = navigationAction.request.url else {
            SessionDiagnostics.shared.record("webview_navigation_blocked missing_url=true")
            decisionHandler(.cancel)
            return
        }

        // `target="_blank"` and `window.open()` have no target frame. Keep the
        // call/session in the one persistent WKWebView and always hand a valid
        // HTTP(S) new-tab destination to the system browser. ReplayKit and the
        // retained WebView continue running when the browser comes forward.
        if navigationAction.targetFrame == nil {
            if !openInSystemBrowser(destination) {
                SessionDiagnostics.shared.record(
                    "external_navigation_blocked url=\(diagnosticURL(destination))"
                )
            }
            decisionHandler(.cancel)
            return
        }

        guard WebSecurityPolicy.isTrusted(destination) else {
            if session?.isRecording == true {
                SessionDiagnostics.shared.record(
                    "webview_navigation_blocked_untrusted_origin recording=true " +
                    "url=\(diagnosticURL(destination))"
                )
            } else if !openInSystemBrowser(destination) {
                SessionDiagnostics.shared.record(
                    "webview_navigation_blocked_untrusted_origin url=\(diagnosticURL(destination))"
                )
            }
            decisionHandler(.cancel)
            return
        }

        SessionDiagnostics.shared.record(
            "webview_navigate url=\(diagnosticURL(destination))"
        )
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           (500...599).contains(response.statusCode) {
            SessionDiagnostics.shared.record(
                "webview_server_error status=\(response.statusCode) " +
                "url=\(diagnosticURL(response.url))"
            )
            Task { @MainActor [weak self] in
                self?.session?.webViewLoadFailed = true
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Defensive fallback for WebKit versions that reach the UI delegate
        // without first calling the navigation-policy delegate.
        if !handleAppDeepLink(navigationAction.request.url) {
            if !openInSystemBrowser(navigationAction.request.url) {
                SessionDiagnostics.shared.record(
                    "external_navigation_blocked_fallback " +
                    "url=\(diagnosticURL(navigationAction.request.url))"
                )
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        SessionDiagnostics.shared.record("webview_loading url=\(diagnosticURL(webView.url))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        Task { @MainActor [weak self] in
            self?.session?.webViewLoadFailed = false
        }
        SessionDiagnostics.shared.record("webview_loaded url=\(diagnosticURL(webView.url))")
        store?.sampleMediaState(reason: "navigation_finished", force: true)
        CallAudioSessionManager.shared.logCurrentState(event: "audio_after_webview_load")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        reportLoadFailureIfNeeded(error)
        SessionDiagnostics.shared.record("webview_failed error=\(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        webView.scrollView.refreshControl?.endRefreshing()
        reportLoadFailureIfNeeded(error)
        SessionDiagnostics.shared.record(
            "webview_provisional_failed error=\(error.localizedDescription) " +
            "url=\(diagnosticURL(webView.url))"
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        store?.handleWebContentTermination(webView)
    }

    private func reportLoadFailureIfNeeded(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.session?.webViewLoadFailed = true
        }
    }

    private func handleAppDeepLink(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == RecorderConstants.customURLScheme else { return false }

        SessionDiagnostics.shared.record("webview_app_deep_link url=\(diagnosticURL(url))")
        Task { @MainActor [weak self] in
            self?.session?.handleDeepLink(url)
        }
        return true
    }

    private func openInSystemBrowser(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }

        SessionDiagnostics.shared.record("external_navigation_opened url=\(diagnosticURL(url))")
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                SessionDiagnostics.shared.record(
                    "external_navigation_open_failed url=\(diagnosticURL(url))"
                )
            }
        }
        return true
    }

    private static func jsonString(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        return String(encoded.dropFirst().dropLast())
    }
}
