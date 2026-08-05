//  StopView.swift
//  SatellicaRecorder — upload progress with ring gauge.
//  Matches ios-05-complete-then-upload-v7.html design.
//  Phase 1: "Session Completed" (held 2s) → Phase 2: ring upload progress → Done.

import SwiftUI

struct StopView: View {
    @EnvironmentObject private var session: SessionManager
    @ObservedObject private var uploader = ChunkUploader.shared

    @State private var showUpload = false
    @State private var appear = false

    private var isComplete: Bool { session.broadcastStatus == "completed" }
    private var hasUploadError: Bool { uploader.uploadError != nil }

    private var progress: Double {
        guard uploader.chunksTotal > 0 else { return 0 }
        return Double(uploader.chunksUploaded) / Double(uploader.chunksTotal)
    }

    private var uploadHeadline: String {
        if isComplete { return "Recording uploaded" }
        if hasUploadError { return "Upload needs attention" }
        switch uploader.activity {
        case .reconciling: return "Checking upload status"
        case .verifying: return "Verifying your recording"
        case .finalizing: return "Finalizing your recording"
        case .retrying: return "Retrying automatically"
        default:
            return progress >= 1 ? "Finalizing your recording" : "Uploading your recording"
        }
    }

    private var uploadDetail: String {
        if isComplete {
            return "Everything has been submitted. You can close the app now."
        }
        if hasUploadError {
            return "The recording is still stored safely on this device. Please keep the app installed and contact support."
        }
        switch uploader.activity {
        case .reconciling:
            return "Checking saved files and any uploads that were already in progress."
        case .verifying:
            return "Checking every local video file and repairing its timing information before submission."
        case .finalizing:
            return "All video files are uploaded. Waiting for the server to accept the complete recording."
        case .retrying:
            return "Your files remain safely on this device. Satellica will keep checking and retrying automatically."
        default:
            return "Your session isn't submitted until this finishes. Please keep Satellica open."
        }
    }

    var body: some View {
        ZStack {
            STheme.shellGradient.ignoresSafeArea()

            if !showUpload {
                // Phase 1 — "Session Completed" (web-style)
                completedPhase
                    .transition(.opacity)
            } else {
                // Phase 2 — Native upload page
                uploadPhase
                    .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            // Start handover line animation immediately
            withAnimation(.linear(duration: 2)) {
                handoverProgress = 1
            }

            // After 2s hold, transition to upload phase
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    showUpload = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        appear = true
                    }
                }
            }
        }
    }

    // MARK: - Phase 1: Session Completed

    private var completedPhase: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 11) {
                Image("SatellicaIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                Text("Checkout Flow Study")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            Spacer()

            // Green check
            ZStack {
                Circle()
                    .fill(STheme.ok)
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("Session Completed")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color(hex: 0x111827))
                .padding(.top, 18)

            Text("Thank you for your participation in this survey!")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: 0x4B5563))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 290)
                .padding(.top, 20)

            Spacer()

            // Handover line
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [STheme.gradA, STheme.gradB],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
                    .frame(width: geo.size.width * handoverProgress)
                    .animation(.linear(duration: 2), value: handoverProgress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2)
            .onAppear {
                // Animate handover line across 2 seconds
            }
        }
    }

    @State private var handoverProgress: Double = 0

    // MARK: - Phase 2: Upload

    private var uploadPhase: some View {
        VStack(spacing: 0) {
            // Brand header — same position as Phase 1
            HStack(spacing: 11) {
                SatellicaMark()
                    .frame(width: 28, height: 28)
                Text("Checkout Flow Study")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                Spacer()
            }
            .padding(.horizontal, 34)
            .padding(.top, 16)
            .opacity(appear ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.08), value: appear)

            Spacer()

            // Ring progress
            ZStack {
                // Track
                Circle()
                    .stroke(
                        isComplete ? STheme.ok.opacity(0.16) : STheme.primary.opacity(0.14),
                        lineWidth: 3
                    )
                    .frame(width: 140, height: 140)

                // Fill
                if !isComplete {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            LinearGradient(
                                colors: [STheme.gradA, STheme.gradB],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 140, height: 140)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: progress)
                }

                // Center content
                if isComplete {
                    // Green checkmark
                    ZStack {
                        Circle()
                            .fill(STheme.ok)
                            .frame(width: 62, height: 62)
                        Image(systemName: "checkmark")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    // Percentage
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(STheme.ink)
                        .monospacedDigit()
                }
            }
            .scaleEffect(appear ? 1 : 0.9)
            .animation(.easeOut(duration: 0.68).delay(0.18), value: appear)

            // Copy
            VStack(spacing: 10) {
                Text(uploadHeadline)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: 0x111827))

                Text(uploadDetail)
                    .font(.system(size: 14))
                    .foregroundStyle(STheme.meta)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 258)
            }
            .padding(.top, 34)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 10)
            .animation(.easeOut(duration: 0.48).delay(0.38), value: appear)

            Spacer()

            ShareLink(item: RecorderConstants.diagnosticsURL) {
                Label("Export diagnostic log", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(STheme.primary)
            }
            .padding(.bottom, 16)

            // Done button — only after upload confirmed
            if isComplete {
                Button {
                    session.resetCompletedSession()
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(STheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: STheme.primary.opacity(0.75), radius: 12, y: 8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 34)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.45).delay(0.3), value: isComplete)
    }
}
