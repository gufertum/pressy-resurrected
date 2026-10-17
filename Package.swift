// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Embedded into the binary so privacy prompts and TCC entries show a bundle id instead of a bare path.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "pressy",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(name: "PressyCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .executableTarget(
            name: "pressy",
            dependencies: ["PressyCore"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        // The menu bar app; scripts/build-app.sh wraps it into Pressy.app.
        .executableTarget(name: "PressyBar", dependencies: ["PressyCore"]),
        .testTarget(name: "PressyCoreTests", dependencies: ["PressyCore"]),
    ]
)
