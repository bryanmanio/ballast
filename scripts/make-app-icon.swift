// Renders the app icon from `BallastMark` — the same drawing as the favicon
// on ballast.ing — into Assets.xcassets, so the icon can never drift from
// the mark the app and the site both use.
//
//   swiftc scripts/make-app-icon.swift Ballast/Ballast/UI/BallastMark.swift \
//       -o /tmp/make-app-icon && /tmp/make-app-icon
//
// Run it again after changing the mark.

import AppKit
import SwiftUI

/// macOS leaves a margin around an app icon's artwork rather than filling the
/// tile edge to edge; 824 of 1024 is the proportion Apple's own icons use.
let artworkRatio: CGFloat = 824.0 / 1024.0

@MainActor
func renderIcon(pixels: CGFloat) -> Data? {
    let content = ZStack {
        Color.clear
        BallastMark(size: pixels * artworkRatio)
    }
    .frame(width: pixels, height: pixels)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 1
    renderer.isOpaque = false
    guard let cgImage = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
}

/// Every slot a macOS icon set asks for, as (points, scale).
let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

let iconSet = URL(fileURLWithPath: "Ballast/Ballast/Assets.xcassets/AppIcon.appiconset")

@main
struct MakeAppIcon {
    @MainActor
    static func main() {
        var images: [[String: String]] = []

        for slot in slots {
            let pixels = slot.points * slot.scale
            let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
            guard let data = renderIcon(pixels: CGFloat(pixels)) else {
                FileHandle.standardError.write(Data("Couldn't render \(name)\n".utf8))
                exit(1)
            }
            try! data.write(to: iconSet.appendingPathComponent(name))
            images.append([
                "idiom": "mac",
                "size": "\(slot.points)x\(slot.points)",
                "scale": "\(slot.scale)x",
                "filename": name,
            ])
            print("\(name) — \(pixels)px")
    }

        let contents: [String: Any] = [
            "images": images,
            "info": ["author": "xcode", "version": 1],
        ]
        let json = try! JSONSerialization.data(
            withJSONObject: contents,
            options: [.prettyPrinted, .sortedKeys]
        )
        try! json.write(to: iconSet.appendingPathComponent("Contents.json"))
    }
}
