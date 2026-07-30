//  BroadcastTrigger.swift
//  SatellicaRecorder — SwiftUI wrapper for RPSystemBroadcastPickerView.

import SwiftUI
import ReplayKit

struct BroadcastTriggerButton: UIViewRepresentable {
    var tintColor: UIColor = UIColor(STheme.destructive)

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        picker.preferredExtension = RecorderConstants.broadcastBundleId
        picker.showsMicrophoneButton = true
        if let button = picker.subviews.compactMap({ $0 as? UIButton }).first {
            let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
            button.setImage(UIImage(systemName: "record.circle", withConfiguration: config), for: .normal)
            button.tintColor = tintColor
            // Make button fill the picker view
            button.frame = picker.bounds
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        picker.backgroundColor = .clear
        picker.isUserInteractionEnabled = true
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}

    /// Programmatically show the system broadcast picker (for auto-start via Universal Link).
    static func trigger() {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = RecorderConstants.broadcastBundleId
        picker.showsMicrophoneButton = true
        picker.subviews.compactMap { $0 as? UIButton }.first?
            .sendActions(for: .allTouchEvents)
    }
}
