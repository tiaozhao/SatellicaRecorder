//  SatellicaLogo.swift
//  SatellicaRecorder — SVG logo paths extracted from Satellica HTML.
//  Two components: SatellicaMark (icon only) and SatellicaWordmark (full logo with text).

import SwiftUI

// MARK: - Icon mark (viewBox 0 0 155.4 155.27)
// Used in headers, small contexts. Two leaf shapes with gradient.

struct SatellicaMark: View {
    var body: some View {
        ZStack {
            // Left leaf — gradient #591BD4 → #3B6AB3
            SatellicaLeftLeaf()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x591BD4), location: 0),
                            .init(color: Color(hex: 0x5427CE), location: 0.45),
                            .init(color: Color(hex: 0x3B6AB3), location: 0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Right leaf
            SatellicaRightLeaf()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x591BD4), location: 0.45),
                            .init(color: Color(hex: 0x3B6AB3), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .aspectRatio(155.4 / 155.27, contentMode: .fit)
    }
}

// MARK: - Full wordmark (used on HomeView cold open)
// Renders the icon mark at a larger size since we can't easily reproduce
// the full SVG text paths. Paired with "Satellica" text below.

struct SatellicaWordmark: View {
    var body: some View {
        VStack(spacing: 18) {
            SatellicaMark()
                .frame(width: 72, height: 72)

            Text("satellica")
                .font(.system(size: 28, weight: .medium, design: .default))
                .tracking(3)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x591BD4), location: 0),
                            .init(color: Color(hex: 0x3B6AB3), location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}

// MARK: - SVG Path shapes (exact paths from HTML)

private struct SatellicaLeftLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 155.4
        let sy = rect.height / 155.27
        var p = Path()
        p.move(to: CGPoint(x: 71.94 * sx, y: 109.17 * sy))
        p.addCurve(to: CGPoint(x: 78.41 * sx, y: 102.75 * sy),
                    control1: CGPoint(x: 74.78 * sx, y: 107.32 * sy),
                    control2: CGPoint(x: 77.05 * sx, y: 105.1 * sy))
        p.addCurve(to: CGPoint(x: 75.05 * sx, y: 85.24 * sy),
                    control1: CGPoint(x: 83.48 * sx, y: 94.02 * sy),
                    control2: CGPoint(x: 76.5 * sx, y: 86.63 * sy))
        p.addCurve(to: CGPoint(x: 60.66 * sx, y: 48.65 * sy),
                    control1: CGPoint(x: 70.24 * sx, y: 80.67 * sy),
                    control2: CGPoint(x: 55.78 * sx, y: 66.91 * sy))
        p.addCurve(to: CGPoint(x: 80.31 * sx, y: 23.01 * sy),
                    control1: CGPoint(x: 63.5 * sx, y: 38.07 * sy),
                    control2: CGPoint(x: 70.48 * sx, y: 28.95 * sy))
        p.addLine(to: CGPoint(x: 108.08 * sx, y: 6.21 * sy))
        p.addCurve(to: CGPoint(x: 63.11 * sx, y: 1.63 * sy),
                    control1: CGPoint(x: 94.9 * sx, y: 0.61 * sy),
                    control2: CGPoint(x: 79.91 * sx, y: -1.9 * sy))
        p.addCurve(to: CGPoint(x: 0.81 * sx, y: 66.49 * sy),
                    control1: CGPoint(x: 31.05 * sx, y: 8.38 * sy),
                    control2: CGPoint(x: 5.51 * sx, y: 34.07 * sy))
        p.addCurve(to: CGPoint(x: 27.01 * sx, y: 136.44 * sy),
                    control1: CGPoint(x: -3.14 * sx, y: 93.75 * sy),
                    control2: CGPoint(x: 7.61 * sx, y: 119.69 * sy))
        p.addLine(to: CGPoint(x: 71.94 * sx, y: 109.17 * sy))
        p.closeSubpath()
        return p
    }
}

private struct SatellicaRightLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 155.4
        let sy = rect.height / 155.27
        var p = Path()
        p.move(to: CGPoint(x: 128.4 * sx, y: 18.84 * sy))
        p.addLine(to: CGPoint(x: 91.36 * sx, y: 41.25 * sy))
        p.addCurve(to: CGPoint(x: 81.27 * sx, y: 54.17 * sy),
                    control1: CGPoint(x: 86.33 * sx, y: 44.29 * sy),
                    control2: CGPoint(x: 82.0 * sx, y: 48.75 * sy))
        p.addCurve(to: CGPoint(x: 89.7 * sx, y: 69.73 * sy),
                    control1: CGPoint(x: 81.06 * sx, y: 55.69 * sy),
                    control2: CGPoint(x: 79.66 * sx, y: 60.19 * sy))
        p.addCurve(to: CGPoint(x: 96.85 * sx, y: 113.46 * sy),
                    control1: CGPoint(x: 96.96 * sx, y: 76.39 * sy),
                    control2: CGPoint(x: 107.99 * sx, y: 94.29 * sy))
        p.addCurve(to: CGPoint(x: 83.29 * sx, y: 127.22 * sy),
                    control1: CGPoint(x: 93.8 * sx, y: 118.72 * sy),
                    control2: CGPoint(x: 89.23 * sx, y: 123.33 * sy))
        p.addLine(to: CGPoint(x: 47.31 * sx, y: 149.06 * sy))
        p.addCurve(to: CGPoint(x: 92.28 * sx, y: 153.64 * sy),
                    control1: CGPoint(x: 60.49 * sx, y: 154.66 * sy),
                    control2: CGPoint(x: 75.48 * sx, y: 157.17 * sy))
        p.addCurve(to: CGPoint(x: 154.58 * sx, y: 88.8 * sy),
                    control1: CGPoint(x: 124.33 * sx, y: 146.9 * sy),
                    control2: CGPoint(x: 149.88 * sx, y: 121.22 * sy))
        p.addCurve(to: CGPoint(x: 128.4 * sx, y: 18.84 * sy),
                    control1: CGPoint(x: 158.54 * sx, y: 61.54 * sy),
                    control2: CGPoint(x: 147.8 * sx, y: 35.59 * sy))
        p.closeSubpath()
        return p
    }
}
