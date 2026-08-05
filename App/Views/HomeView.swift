//  HomeView.swift
//  SatellicaRecorder — app-ready landing page.

import SwiftUI

struct HomeView: View {
    private let pageBackground = Color(hex: 0xF6F7FF)
    private let foreground = Color(hex: 0x171717)
    private let muted = Color(hex: 0x737373)
    private let border = Color(hex: 0xE6E7F2)

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    successBlock
                    heading
                    optionsCard
                    footer
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 48))
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
        }
        .background(pageBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var successBlock: some View {
        SatellicaMark()
            .frame(width: 56, height: 56)
            .frame(width: 76, height: 76)
            .padding(.top, 26)
    }

    private var heading: some View {
        VStack(spacing: 12) {
            Text("Ready to start?")
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.26)
                .foregroundStyle(foreground)

            Text("Start your interview by either way below.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 300)
        }
        .padding(.top, 28)
    }

    private var optionsCard: some View {
        VStack(spacing: 0) {
            LandingOption(
                imageName: "InvitationIllustration",
                title: "Open the invitation",
                description: "Open the invitation on your phone, and tap the button to start."
            )

            orDivider
                .padding(.vertical, 26)

            LandingOption(
                imageName: "QRIllustration",
                title: "Scan the QR code",
                description: "Open the invitation on a computer, and scan the QR code to start."
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        }
        .padding(.top, 36)
    }

    private var orDivider: some View {
        HStack(spacing: 16) {
            Rectangle()
                .fill(border)
                .frame(height: 1)

            Text("OR")
                .font(.system(size: 15, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(STheme.primary)

            Rectangle()
                .fill(border)
                .frame(height: 1)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("Can't find your invitation?")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(muted)

            Text("Contact your study coordinator")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(STheme.primary)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 40)
    }
}

private struct LandingOption: View {
    let imageName: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(imageName)
                .resizable()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.075)
                    .foregroundStyle(Color(hex: 0x171717))

                Text(description)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Color(hex: 0x737373))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
