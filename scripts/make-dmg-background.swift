// Renders the background of the disk image's Finder window: the "drag Ballast
// to Applications" line, and the chevrons that sit between the two icons.
// `make-dmg.sh` runs it on every build, so the window can't drift from the
// app's name or the icon positions it lays out.
//
//   swiftc scripts/make-dmg-background.swift -o /tmp/make-dmg-background
//   /tmp/make-dmg-background Ballast out.png
//
// Positions are in points, top-left origin, matching what Finder is told in
// `make-dmg.sh`. Change both together.

import AppKit
import SwiftUI

let windowSize = CGSize(width: 800, height: 400)
/// Centre line of both icons.
let iconY: CGFloat = 180

struct Background: View {
    var appName: String

    var body: some View {
        ZStack {
            Color(white: 0.97)

            // Soft light leaking in at the corners: open sky above, and water
            // along the bottom edge, where a ballast sits.
            glow(Color(red: 0.60, green: 0.78, blue: 1.0), at: .topLeading, radius: 190, opacity: 0.55)
            glow(Color(red: 0.58, green: 0.92, blue: 0.88), at: .topTrailing, radius: 190, opacity: 0.5)
            LinearGradient(
                colors: [.clear, Color(red: 0.66, green: 0.76, blue: 0.96).opacity(0.55)],
                startPoint: UnitPoint(x: 0.5, y: 0.68),
                endPoint: .bottom
            )
            glow(Color(red: 0.45, green: 0.66, blue: 0.98), at: .bottomLeading, radius: 230, opacity: 0.35)
            glow(Color(red: 0.50, green: 0.80, blue: 0.95), at: .bottomTrailing, radius: 230, opacity: 0.35)

            instruction
                .position(x: windowSize.width / 2, y: 53)

            Chevrons()
                .position(x: windowSize.width / 2, y: iconY)
        }
        .frame(width: windowSize.width, height: windowSize.height)
    }

    private var instruction: some View {
        let app = Text(appName).fontWeight(.semibold).foregroundStyle(Color(white: 0.05))
        let applications = Text("Applications").fontWeight(.semibold).foregroundStyle(Color(white: 0.05))
        return Text("To install, drag \(app) to \(applications)")
            .foregroundStyle(Color(white: 0.42))
            .font(.system(size: 16))
            .fixedSize()
    }

    private func glow(_ color: Color, at corner: UnitPoint, radius: CGFloat, opacity: Double) -> some View {
        RadialGradient(
            colors: [color.opacity(opacity), color.opacity(0)],
            center: corner,
            startRadius: 0,
            endRadius: radius
        )
    }
}

/// Three chevrons fading in from left to right, pointing at Applications.
struct Chevrons: View {
    private let shades: [Double] = [0.78, 0.48, 0.05]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(shades.indices, id: \.self) { index in
                Chevron()
                    .stroke(Color(white: shades[index]),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 9, height: 19)
            }
        }
    }

    private struct Chevron: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            return path
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background <app name> <out.png>\n".utf8))
    exit(2)
}

// Top-level code runs on the main thread, which ImageRenderer requires.
let png = MainActor.assumeIsolated { () -> Data? in
    let renderer = ImageRenderer(content: Background(appName: arguments[1]))
    renderer.scale = 2
    guard let cgImage = renderer.cgImage else { return nil }

    // Sized in points so the PNG carries 144 dpi, which is how Finder knows
    // to draw it at half its pixel size rather than cropping it.
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = windowSize
    return bitmap.representation(using: .png, properties: [:])
}
guard let png else {
    FileHandle.standardError.write(Data("Couldn't render the background\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: arguments[2]))
