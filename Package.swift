// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirSculpt",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AirSculpt",
            path: "Sources/AirSculpt",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the executable's __TEXT,__info_plist section.
                // This is what lets a bare SwiftPM executable use the camera:
                // macOS requires NSCameraUsageDescription to be present in the
                // process's Info.plist or AVFoundation aborts the process.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AirSculpt/Info.plist",
                ])
            ]
        )
    ]
)
