//  RecorderApp.swift
//  SatellicaRecorder — app entry point + AppDelegate for background uploads.

import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    static let externalURLNotification = Notification.Name("RecorderExternalURLReceived")
    private static var pendingExternalURL: URL?

    static func takePendingExternalURL() -> URL? {
        defer { pendingExternalURL = nil }
        return pendingExternalURL
    }

    private static func captureExternalURL(_ url: URL) {
        pendingExternalURL = url
        NotificationCenter.default.post(
            name: externalURLNotification,
            object: url
        )
    }

    private static func externalURL(in value: Any) -> URL? {
        if let activity = value as? NSUserActivity,
           activity.activityType == NSUserActivityTypeBrowsingWeb {
            return activity.webpageURL
        }
        if let values = value as? [AnyHashable: Any] {
            for nestedValue in values.values {
                if let url = externalURL(in: nestedValue) { return url }
            }
        }
        if let values = value as? [Any] {
            for nestedValue in values {
                if let url = externalURL(in: nestedValue) { return url }
            }
        }
        return nil
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let url = launchOptions?[.url] as? URL {
            Self.captureExternalURL(url)
        } else if let activityPayload = launchOptions?[.userActivityDictionary],
                  let url = Self.externalURL(in: activityPayload) {
            Self.captureExternalURL(url)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return false }
        Self.captureExternalURL(url)
        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Self.captureExternalURL(url)
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        ChunkUploader.shared.handleBackgroundSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct RecorderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = SessionManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var initialRouteResolved = false
    @State private var initialResolutionScheduled = false

    var body: some Scene {
        WindowGroup {
        Group {
            if initialRouteResolved {
                NavigationStack(path: $session.path) {
                    HomeView()
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .start:   StartView()
                            case .stop:    StopView()
                            case .session: SessionWebViewPage()
                            }
                        }
                }
            } else {
                InitialRouteView()
            }
        }
        .onAppear {
            guard !initialResolutionScheduled else { return }
            initialResolutionScheduled = true
            if let pendingURL = AppDelegate.takePendingExternalURL() {
                routeExternalURL(pendingURL)
                return
            }
            Task { @MainActor in
                // Universal Links arrive through the scene shortly after cold
                // launch on some OS versions. Keep the short grace period as
                // a fallback when neither delegate callback arrives early.
                try? await Task.sleep(for: .milliseconds(350))
                if let pendingURL = AppDelegate.takePendingExternalURL() {
                    routeExternalURL(pendingURL)
                } else {
                    resolveInitialRouteIfNeeded()
                }
            }
        }
        .environmentObject(session)
        .onOpenURL { url in
            routeExternalURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            routeExternalURL(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.externalURLNotification)) {
            notification in
            guard let url = notification.object as? URL else { return }
            _ = AppDelegate.takePendingExternalURL()
            routeExternalURL(url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            session.handleScenePhase(newPhase)
        }
        .alert(item: $session.sessionExitAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("Exit Interview")) {
                    session.leaveInterruptedSession()
                }
            )
        }
        }
    }

    @MainActor
    private func routeExternalURL(_ url: URL) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            session.handleDeepLink(url)
            initialRouteResolved = true
        }
    }

    @MainActor
    private func resolveInitialRouteIfNeeded() {
        guard !initialRouteResolved else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            initialRouteResolved = true
        }
    }
}

private struct InitialRouteView: View {
    var body: some View {
        ZStack {
            STheme.shellGradient.ignoresSafeArea()
            SatellicaMark()
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)
        }
    }
}

enum AppRoute: Hashable {
    case start, stop, session
}
