// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WristRemoteProtocol",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "WristRemote",
            path: "Shared"
        ),
        .testTarget(
            name: "WristRemoteTests",
            dependencies: ["WristRemote"],
            path: "Tests"
        ),
    ]
)
