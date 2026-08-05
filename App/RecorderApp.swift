//  RecorderApp.swift
//  SatellicaRecorder — app entry point + AppDelegate for background uploads.

import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
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

    var body: some Scene {
        WindowGroup {
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
        .animation(.easeInOut(duration: 0.25), value: session.path)
        .environmentObject(session)
        .onOpenURL { url in
            session.handleDeepLink(url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            session.handleScenePhase(newPhase)
        }
        }
    }
}

enum AppRoute: Hashable {
    case start, stop, session
}
