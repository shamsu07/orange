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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
    ],
    targets: [
        .target(name: "OrangeCore"),
        .target(name: "OrangeArtwork"),
        .executableTarget(
            name: "Orange",
            dependencies: ["OrangeCore", "OrangeArtwork", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "OrangeIconGenerator", dependencies: ["OrangeArtwork"]),
        .executableTarget(name: "OrangeBench", dependencies: ["OrangeCore"]),
        .testTarget(name: "OrangeCoreTests", dependencies: ["OrangeCore"]),
        .testTarget(name: "OrangeAppTests", dependencies: ["Orange"])
    ],
    swiftLanguageModes: [.v5]
)
