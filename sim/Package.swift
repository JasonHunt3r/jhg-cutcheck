// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CutSim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CutSimCore", targets: ["CutSimCore"]),
        .executable(name: "cutsim", targets: ["cutsim"]),
        .executable(name: "CutSimApp", targets: ["CutSimApp"]),
    ],
    targets: [
        .target(name: "CutSimCore"),
        .executableTarget(name: "cutsim", dependencies: ["CutSimCore"]),
        .executableTarget(name: "CutSimApp", dependencies: ["CutSimCore"]),
        .testTarget(name: "CutSimCoreTests", dependencies: ["CutSimCore"]),
    ]
)
