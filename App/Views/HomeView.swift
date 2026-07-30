//  HomeView.swift
//  SatellicaRecorder — default landing page with test controls.

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        ZStack {
            STheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Logo
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(STheme.primary.opacity(0.1))
                                .frame(width: 96, height: 96)
                            Image(systemName: "tv.and.mediabox")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(STheme.primary)
                        }
                        Text("Satellica Recorder")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(STheme.textPrimary)
                    }
                    .padding(.top, 40)

                    // Status card
                    SCard {
                        VStack(spacing: 12) {
                            HStack {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 10, height: 10)
                                Text(statusText)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(STheme.textPrimary)
                                Spacer()
                            }

                            if session.uploader.chunksTotal > 0 {
                                VStack(spacing: 8) {
                                    HStack {
                                        Text("Chunks")
                                            .font(.system(size: 13))
                                            .foregroundStyle(STheme.textSecondary)
                                        Spacer()
                                        Text("\(session.uploader.chunksUploaded) / \(session.uploader.chunksTotal)")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(STheme.primary)
                                    }
                                    ProgressView(value: uploadProgress)
                                        .tint(STheme.primary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Test controls
                    SCard {
                        VStack(spacing: 16) {
                            HStack(spacing: 10) {
                                Image(systemName: "hammer.fill")
                                    .foregroundStyle(STheme.warning)
                                    .font(.system(size: 18))
                                Text("Test Controls")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(STheme.textPrimary)
                                Spacer()
                            }

                            // Start recording — broadcast picker
                            VStack(spacing: 8) {
                                Text("Start Recording")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(STheme.textSecondary)
                                BroadcastTriggerButton()
                                    .frame(width: 80, height: 80)
                            }

                            Divider()

                            // Stop recording
                            SButton(title: "Stop Recording", icon: "stop.circle", style: .secondary) {
                                session.requestStop()
                            }

                            // Manual upload trigger
                            SButton(title: "Upload Pending Chunks", icon: "arrow.up.circle", style: .outline) {
                                session.uploader.uploadPendingChunks()
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Upload URL info
                    SCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Upload Endpoint")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(STheme.textPrimary)
                            Text(ChunkUploader.uploadURL?.absoluteString ?? "Not set")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(STheme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Footer
                    Text("Satellica Group Inc.")
                        .font(.system(size: 12))
                        .foregroundStyle(STheme.textSecondary.opacity(0.6))
                        .padding(.bottom, 24)
                }
            }
        }
        .navigationBarHidden(true)
    }

    private var statusColor: Color {
        switch session.broadcastStatus {
        case "recording": STheme.destructive
        case "stopped": STheme.warning
        case "completed": STheme.success
        default: STheme.textSecondary
        }
    }

    private var statusText: String {
        switch session.broadcastStatus {
        case "recording": "Recording"
        case "stopped": "Stopped — uploading"
        case "completed": "Upload complete"
        default: "Idle"
        }
    }

    private var uploadProgress: Double {
        guard session.uploader.chunksTotal > 0 else { return 0 }
        return Double(session.uploader.chunksUploaded) / Double(session.uploader.chunksTotal)
    }
}
