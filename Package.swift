// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TVControlForMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TVControlForMac",
            path: "Sources/TVControlForMac"
        )
    ]
)
