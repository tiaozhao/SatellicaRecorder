//  StartView.swift
//  SatellicaRecorder — shown when Universal Link /recording/start is opened.
//  Explains the recording purpose and auto-triggers the system broadcast picker.

import SwiftUI

struct StartView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var didTrigger = false

    var body: some View {
        ZStack {
            STheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(STheme.primary.opacity(0.1))
                        .frame(width: 100, height: 100)
                    Image(systemName: "rectangle.dashed.badge.record")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(STheme.primary)
                }

                Spacer().frame(height: 24)

                // Title
                Text("Screen Recording")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(STheme.textPrimary)

                Spacer().frame(height: 16)

                // Explanation card
                SCard {
                    VStack(alignment: .leading, spacing: 16) {
                        InfoRow(icon: "checkmark.shield.fill", color: STheme.success,
                                text: "We'll record your screen to help review your testing session.")
                        InfoRow(icon: "lock.fill", color: STheme.primary,
                                text: "The video is only used to improve your experience and is securely uploaded.")
                        InfoRow(icon: "trash.fill", color: STheme.textSecondary,
                                text: "Recordings are automatically deleted from your device after upload.")
                    }
                }
                .padding(.horizontal, 20)

                Spacer().frame(height: 32)

                // Start button area
                VStack(spacing: 16) {
                    if !didTrigger {
                        SButton(title: "Start Recording", icon: "record.circle", style: .primary) {
                            didTrigger = true
                            session.triggerStart()
                        }
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                                .tint(STheme.primary)
                            Text("Waiting for broadcast to start...")
                                .font(.system(size: 14))
                                .foregroundStyle(STheme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                Text("You can stop recording anytime from the status bar")
                    .font(.system(size: 13))
                    .foregroundStyle(STheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 20)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            // Auto-trigger only if not already recording (prevents disruption on re-navigation)
            guard !session.isRecording else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !didTrigger {
                    didTrigger = true
                    session.triggerStart()
                }
            }
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(STheme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
