//  StopView.swift
//  SatellicaRecorder — shown after recording stops. Displays upload progress.

import SwiftUI

struct StopView: View {
    @EnvironmentObject private var session: SessionManager

    private var uploader: ChunkUploader { session.uploader }
    private var isComplete: Bool {
        session.broadcastStatus == "completed"
    }

    var body: some View {
        ZStack {
            STheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Status icon
                ZStack {
                    Circle()
                        .fill(isComplete ? STheme.success.opacity(0.1) : STheme.primary.opacity(0.1))
                        .frame(width: 100, height: 100)
                    Image(systemName: isComplete ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(isComplete ? STheme.success : STheme.primary)
                }

                Spacer().frame(height: 24)

                // Title
                Text(isComplete ? "Upload Complete" : "Recording Complete")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(STheme.textPrimary)

                Spacer().frame(height: 8)

                Text(isComplete
                     ? "All set! Your recording has been uploaded successfully."
                     : "Your recording is being uploaded securely.")
                    .font(.system(size: 15))
                    .foregroundStyle(STheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 32)

                // Upload progress card
                if !isComplete {
                    SCard {
                        VStack(spacing: 16) {
                            // Progress bar
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Uploading")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(STheme.textPrimary)
                                    Spacer()
                                    Text("\(uploader.chunksUploaded) / \(uploader.chunksTotal)")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(STheme.primary)
                                }

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(STheme.surfaceBorder)
                                            .frame(height: 8)
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(STheme.primary)
                                            .frame(width: geo.size.width * progress, height: 8)
                                            .animation(.easeInOut(duration: 0.3), value: progress)
                                    }
                                }
                                .frame(height: 8)
                            }

                            // Status text
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(STheme.textSecondary)
                                Text("Please keep the app open until upload finishes")
                                    .font(.system(size: 13))
                                    .foregroundStyle(STheme.textSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer().frame(height: 32)

                // Actions
                VStack(spacing: 12) {
                    SButton(title: "Back to Website", icon: "safari", style: .primary) {
                        session.returnToWebsite()
                    }
                    if isComplete {
                        SButton(title: "Done", icon: "house", style: .outline) {
                            session.path = []

                            // Clear state
                            let defaults = UserDefaults(suiteName: RecorderConstants.appGroup)
                            defaults?.set("idle", forKey: RecorderConstants.broadcastStatusKey)
                            defaults?.synchronize()
                            session.broadcastStatus = "idle"
                        }
                    }
                }
                .padding(.horizontal, 20)

                Spacer()
            }
        }
        .navigationBarHidden(true)
    }

    private var progress: Double {
        guard uploader.chunksTotal > 0 else { return 0 }
        return Double(uploader.chunksUploaded) / Double(uploader.chunksTotal)
    }
}
