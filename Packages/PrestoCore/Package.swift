// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrestoCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PrestoCore", targets: ["PrestoCore"]),
        .executable(name: "presto-eval", targets: ["presto-eval"]),
    ],
    targets: [
        .target(name: "PrestoCore"),
        .executableTarget(name: "presto-eval", dependencies: ["PrestoCore"]),
        .testTarget(name: "PrestoCoreTests", dependencies: ["PrestoCore"]),
    ]
)
