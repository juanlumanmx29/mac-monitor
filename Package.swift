// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Telemetria",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Telemetria",
            path: "Sources/Telemetria",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
