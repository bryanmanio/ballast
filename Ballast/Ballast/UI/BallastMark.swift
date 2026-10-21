import SwiftUI

/// The app mark, as drawn on the site (`site/favicon.svg`): a white ring with
/// a waterline across it, on a blue gradient tile.
///
/// Redrawn with shapes rather than shipped as an asset so it stays sharp at
/// any size and picks up the same geometry the SVG uses — the numbers below
/// are its 32-unit viewBox, scaled.
struct BallastMark: View {
    var size: CGFloat = 56

    /// One unit of the mark's 32×32 coordinate space.
    private var unit: CGFloat { size / 32 }
    private var ring: CGFloat { 16.5 * unit }

    private static let top = Color(red: 0.231, green: 0.494, blue: 0.878)
    private static let bottom = Color(red: 0.090, green: 0.282, blue: 0.608)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7.5 * unit, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Self.top, Self.bottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Circle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 2.1 * unit)
                .frame(width: ring, height: ring)

            // The waterline: the part of the same circle below y=17.5.
            Circle()
                .fill(.white.opacity(0.95))
                .frame(width: ring, height: ring)
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: 6.75 * unit)
                }
        }
        .frame(width: size, height: size)
        // Pure black or pure white at 10%, never a tinted neutral: a tinted
        // edge picks up the surface behind it and reads as dirt.
        .overlay {
            RoundedRectangle(cornerRadius: 7.5 * unit, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.22), radius: 7 * unit / 2, y: 1.5 * unit)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 16) {
        BallastMark(size: 32)
        BallastMark(size: 56)
        BallastMark(size: 96)
    }
    .padding(32)
}
