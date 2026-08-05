//  HomeView.swift
//  SatellicaRecorder — cold open: Satellica wordmark + one sentence.
//  Matches ios-01-cold-open.html.

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var appear = false

    var body: some View {
        ZStack {
            STheme.shellGradient.ignoresSafeArea()

            // Soft brand bloom
            RadialGradient(
                colors: [STheme.primary.opacity(0.11), STheme.primary.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 180
            )
            .frame(width: 360, height: 360)
            .offset(y: -20)

            VStack(spacing: 30) {
                // Full wordmark SVG from HTML (icon + "satellica" text)
                Image("SatellicaWordmark")
                    .resizable()
                    .aspectRatio(711.0 / 155.27, contentMode: .fit)
                    .frame(width: 178)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 10)
                    .animation(.easeOut(duration: 0.62), value: appear)

                Text("To join a study, tap the invitation link you were sent.")
                    .font(.system(size: 15.5, weight: .regular))
                    .foregroundStyle(STheme.heroSub)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 268)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 10)
                    .animation(.easeOut(duration: 0.62).delay(0.1), value: appear)
            }
        }
        .navigationBarHidden(true)
        .onAppear { appear = true }
    }
}
