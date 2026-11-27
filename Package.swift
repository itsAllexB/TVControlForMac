// swift-tools-version: 5.10
// SPDX-License-Identifier: AGPL-3.0-or-later
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
