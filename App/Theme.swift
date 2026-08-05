//  Theme.swift
//  SatellicaRecorder — design tokens from Satellica globals.css.

import SwiftUI

enum STheme {
    // Brand — from globals.css
    static let primary = Color(hex: 0x6246FF)
    static let primaryHover = Color(hex: 0x4E3BDA)
    static let gradA = Color(hex: 0x4531B3)
    static let gradB = Color(hex: 0x7D65FF)

    // Text
    static let ink = Color(hex: 0x1B1530)
    static let content = Color(hex: 0x2C2C2C)
    static let textSubtle = Color(hex: 0x4A4A4A)
    static let textSecondary = Color(hex: 0x7F7F7F)
    static let heroSub = Color(hex: 0x5A5A6B)
    static let meta = Color(hex: 0x7A7392)

    // Surfaces
    static let whiteW75 = Color(hex: 0xF9F9F9)
    static let borderLight = Color(hex: 0xE2E2E2)
    static let surface = Color.white

    // Status
    static let ok = Color(hex: 0x34C759)
    static let destructive = Color(hex: 0xEF4444)
    static let warning = Color(hex: 0xF59E0B)

    // Shell gradient (white → #E7E9FF)
    static let shellGradient = LinearGradient(
        colors: [.white, Color(hex: 0xE7E9FF)],
        startPoint: .top, endPoint: .bottom
    )

    // Kept for backward compat
    static let textPrimary = ink
    static let textOnPrimary = Color.white
    static let background = Color(hex: 0xF8FAFC)
    static let surfaceBorder = borderLight
    static let success = ok
    static let primaryLight = gradB
    static let primaryDark = gradA
}

// MARK: - Hex color init

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Reusable components

struct SButton: View {
    let title: String
    var icon: String? = nil
    var style: Style = .primary
    var action: () -> Void

    enum Style { case primary, secondary, outline }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(foregroundColor)
            .background(backgroundFill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(STheme.borderLight, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: STheme.textOnPrimary
        case .secondary: STheme.primary
        case .outline: STheme.textPrimary
        }
    }

    @ViewBuilder private var backgroundFill: some View {
        switch style {
        case .primary: STheme.primary
        case .secondary: STheme.primary.opacity(0.1)
        case .outline: Color.clear
        }
    }
}

struct SCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(24)
            .background(STheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }
}
