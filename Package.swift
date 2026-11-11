// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SievePilot",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SievePilotCore", targets: ["SievePilotCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", "2.70.0"..<"2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", "2.29.0"..<"2.35.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", "1.0.0"..<"1.7.0"),
        // Keep transitive resolution compatible with the Swift 5.9 deployment toolchain.
        .package(url: "https://github.com/apple/swift-asn1.git", "1.1.0"..<"1.4.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", "1.1.0"..<"1.3.0"),
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0"..<"1.2.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"3.13.0"),
        .package(url: "https://github.com/apple/swift-system.git", "1.4.0"..<"1.7.0")
    ],
    targets: [
        .target(name: "SievePilotCore", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1")
        ]),
        .testTarget(
            name: "SievePilotCoreTests",
            dependencies: ["SievePilotCore"],
            resources: [.process("Fixtures")]
        )
    ]
)
