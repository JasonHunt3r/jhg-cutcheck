// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CutSim",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CutSimCore", targets: ["CutSimCore"]),
        .executable(name: "cutsim", targets: ["cutsim"]),
    ],
    targets: [
        .target(name: "CutSimCore"),
        .executableTarget(name: "cutsim", dependencies: ["CutSimCore"]),
        .testTarget(name: "CutSimCoreTests", dependencies: ["CutSimCore"]),
    ]
)
