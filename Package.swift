// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orange",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Orange", targets: ["Orange"]),
        .executable(name: "OrangeBench", targets: ["OrangeBench"]),
        .executable(name: "OrangeIconGenerator", targets: ["OrangeIconGenerator"]),
        .library(name: "OrangeCore", targets: ["OrangeCore"])
    ],
    targets: [
        .target(name: "OrangeCore"),
        .target(name: "OrangeArtwork"),
        .executableTarget(name: "Orange", dependencies: ["OrangeCore", "OrangeArtwork"]),
        .executableTarget(name: "OrangeIconGenerator", dependencies: ["OrangeArtwork"], path: "scripts",
                          exclude: ["Info.plist", "build.sh", "test.sh", "package.sh", "build-ffmpeg.sh", "benchmark.sh"], sources: ["MakeIcon.swift"]),
        .executableTarget(name: "OrangeBench", dependencies: ["OrangeCore"]),
        .testTarget(name: "OrangeCoreTests", dependencies: ["OrangeCore"]),
        .testTarget(name: "OrangeAppTests", dependencies: ["Orange"])
    ],
    swiftLanguageModes: [.v5]
)
