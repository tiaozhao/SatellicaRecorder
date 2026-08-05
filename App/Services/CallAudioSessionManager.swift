//  CallAudioSessionManager.swift
//  Configures the app-wide audio session for the real WebView video call.

import AVFoundation

@MainActor
final class CallAudioSessionManager {
    static let shared = CallAudioSessionManager()

    private var observers: [NSObjectProtocol] = []
    private var configured = false

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            Task { @MainActor in
                CallAudioSessionManager.shared.handleInterruption(notification)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            Task { @MainActor in
                CallAudioSessionManager.shared.logRouteChange(notification)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            Task { @MainActor in
                SessionDiagnostics.shared.record("audio_media_services_reset")
                CallAudioSessionManager.shared.configured = false
                CallAudioSessionManager.shared.prepareForWebCall(activate: true)
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Configure semantics only; WebKit/LiveKit remains the sole microphone
    /// capturer. Activation is normally left to WebKit when getUserMedia starts.
    func prepareForWebCall(activate: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        SessionDiagnostics.shared.record(
            "audio_prepare currentCategory=\(session.category.rawValue) " +
            "currentMode=\(session.mode.rawValue) activate=\(activate)"
        )

        do {
            if !configured || session.category != .playAndRecord || session.mode != .videoChat {
                let options: AVAudioSession.CategoryOptions = [
                    .defaultToSpeaker,
                    .allowBluetoothHFP
                ]
                try session.setCategory(.playAndRecord, mode: .videoChat, options: options)
                configured = true
            }
            if activate {
                try session.setActive(true)
            }
            logCurrentState(event: "audio_configured")
        } catch {
            configured = false
            SessionDiagnostics.shared.record("audio_configuration_failed error=\(error.localizedDescription)")
        }
    }

    func logCurrentState(event: String) {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        SessionDiagnostics.shared.record(
            "\(event) category=\(session.category.rawValue) mode=\(session.mode.rawValue) " +
            "inputs=\(inputs) outputs=\(outputs)"
        )
    }

    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            SessionDiagnostics.shared.record("audio_deactivated")
        } catch {
            SessionDiagnostics.shared.record("audio_deactivate_failed error=\(error.localizedDescription)")
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            SessionDiagnostics.shared.record("audio_interruption_began")
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            SessionDiagnostics.shared.record("audio_interruption_ended shouldResume=\(options.contains(.shouldResume))")
            if options.contains(.shouldResume) {
                prepareForWebCall(activate: true)
            }
        @unknown default:
            SessionDiagnostics.shared.record("audio_interruption_unknown")
        }
    }

    private func logRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)?.rawValue ?? rawReason
        logCurrentState(event: "audio_route_changed reason=\(reason)")
    }
}
