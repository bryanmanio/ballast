import SwiftUI

/// The Ballast mark — the same drawing as the favicon on ballast.ing, so the
/// app and the site are recognisably one thing.
///
/// Redrawn rather than imported as a bitmap: it's three shapes, and a vector
/// stays sharp at every size the app asks for. The geometry is kept in the
/// favicon's own 32-unit grid and scaled from there, so the two can't drift.
struct BallastMark: View {
    /// Edge length. The mark is square.
    var size: CGFloat = 72
    /// The rounded square behind the glyph.
    var showsBackground = true

    private var scale: CGFloat { size / 32 }

    var body: some View {
        ZStack {
            if showsBackground {
                RoundedRectangle(cornerRadius: 7.5 * scale, style: .continuous)
                    .fill(Self.gradient)
            }

            // The hull: a ring whose outer edge is r=8.25 and inner r=6.15.
            Circle()
                .strokeBorder(.white, lineWidth: 2.1 * scale)
                .frame(width: 16.5 * scale, height: 16.5 * scale)

            // The water it sits in: the lower segment of that same circle.
            Waterline()
                .fill(.white)
                .frame(width: 16.5 * scale, height: 16.5 * scale)
        }
        .opacity(0.95)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Top to bottom, as on the site.
    static let gradient = LinearGradient(
        colors: [Color(red: 0.231, green: 0.494, blue: 0.878),
                 Color(red: 0.090, green: 0.282, blue: 0.608)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The part of a circle below its load line — the one thing ballast is
    /// for. Cut 1.5 units below centre, as the favicon does.
    private struct Waterline: Shape {
        func path(in rect: CGRect) -> Path {
            let radius = min(rect.width, rect.height) / 2
            let depth = radius * (1.5 / 8.25)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let halfChord = (radius * radius - depth * depth).squareRoot()
            let angle = atan2(depth, halfChord)

            var path = Path()
            path.move(to: CGPoint(x: center.x - halfChord, y: center.y + depth))
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(.pi - angle),
                endAngle: .radians(angle),
                clockwise: true
            )
            path.closeSubpath()
            return path
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        BallastMark(size: 128)
        BallastMark(size: 72)
        BallastMark(size: 32)
    }
    .padding(24)
}
