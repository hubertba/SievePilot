// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SievePilot",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SievePilotCore", targets: ["SievePilotCore"])
    ],
    targets: [
        .target(name: "SievePilotCore"),
        .testTarget(name: "SievePilotCoreTests", dependencies: ["SievePilotCore"])
    ]
)
