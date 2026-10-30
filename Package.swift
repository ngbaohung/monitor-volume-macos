// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MonitorVolume",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MonitorVolume",
            path: "Sources/MonitorVolume",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
