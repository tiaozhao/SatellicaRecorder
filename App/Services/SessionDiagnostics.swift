//  SessionDiagnostics.swift
//  Lightweight, persistent diagnostics for long-running WebView calls.

import Foundation
import UIKit
import os

@MainActor
final class SessionDiagnostics {
    static let shared = SessionDiagnostics()

    private let launchId = UUID().uuidString
    private let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
    private let formatter = ISO8601DateFormatter()
    private let logURL = RecorderConstants.containerURL.appendingPathComponent("session-diagnostics.log")
    private var heartbeatTimer: Timer?
    private var memoryWarningObserver: NSObjectProtocol?
    private var heartbeatCount = 0

    private init() {
        let previousLaunchId = defaults?.string(forKey: "diagnostics_launch_id") ?? "none"
        let previousHeartbeat = defaults?.double(forKey: "diagnostics_last_heartbeat") ?? 0
        defaults?.set(launchId, forKey: "diagnostics_launch_id")

        RecorderLog.write("app", "app_launch", [
            "launchId": launchId,
            "previousLaunchId": previousLaunchId,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "osVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model
        ])

        record(
            "app_launch launchId=\(launchId) previousLaunchId=\(previousLaunchId) " +
            "previousHeartbeat=\(previousHeartbeat)"
        )

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                SessionDiagnostics.shared.record("memory_warning")
            }
        }

        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                SessionDiagnostics.shared.heartbeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        heartbeat()
    }

    deinit {
        heartbeatTimer?.invalidate()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func record(_ message: String) {
        let availableMB = Double(os_proc_available_memory()) / 1_048_576
        let line = "\(formatter.string(from: Date())) launch=\(launchId) " +
            "availableMB=\(String(format: "%.1f", availableMB)) \(message)\n"
        print("[Diagnostics] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        append(line)
        RecorderLog.write("app", "diagnostic", ["message": message])
    }

    private func heartbeat() {
        let now = Date().timeIntervalSince1970
        defaults?.set(now, forKey: "diagnostics_last_heartbeat")
        heartbeatCount += 1
        if heartbeatCount % 12 == 0 {
            record("heartbeat")
        }
    }

    private func append(_ line: String) {
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if fileSize > 2_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }

        let data = Data(line.utf8)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? data.write(to: logURL, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            print("[Diagnostics] log append failed: \(error.localizedDescription)")
        }
    }
}
