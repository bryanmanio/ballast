// swift-tools-version: 6.0
import PackageDescription

// The app's pure logic lives in Ballast/Ballast/Core, which is inside the
// Xcode target's synchronized source folder. Pointing a SwiftPM target at the
// same directory means `swift test` can exercise that logic directly, with no
// duplicated sources and no test target to wire into project.pbxproj.
let package = Package(
    name: "BallastCore",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "BallastCore", path: "Ballast/Ballast/Core"),
        .testTarget(
            name: "BallastCoreTests",
            dependencies: ["BallastCore"],
            path: "Tests/BallastCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
