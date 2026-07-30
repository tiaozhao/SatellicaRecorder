//  Theme.swift
//  SatellicaRecorder — design system matching Satellica website.

import SwiftUI

enum STheme {
    // Brand
    static let primary = Color(hex: 0x4F46E5)       // Indigo 600
    static let primaryLight = Color(hex: 0x6366F1)   // Indigo 500
    static let primaryDark = Color(hex: 0x3730A3)    // Indigo 800

    // Backgrounds
    static let background = Color(hex: 0xF8FAFC)    // Slate 50
    static let surface = Color.white
    static let surfaceBorder = Color(hex: 0xE2E8F0)  // Slate 200

    // Text
    static let textPrimary = Color(hex: 0x0F172A)    // Slate 900
    static let textSecondary = Color(hex: 0x64748B)  // Slate 500
    static let textOnPrimary = Color.white

    // Status
    static let success = Color(hex: 0x10B981)        // Emerald 500
    static let destructive = Color(hex: 0xEF4444)    // Red 500
    static let warning = Color(hex: 0xF59E0B)        // Amber 500
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(STheme.surfaceBorder, lineWidth: 1.5)
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
