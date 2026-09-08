// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HidanClub",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HidanClub", targets: ["HidanClub"]), .library(name: "HidanCore", targets: ["HidanCore"])],
    targets: [
        .target(name: "HidanCore"),
        .executableTarget(name: "HidanClub", dependencies: ["HidanCore"], resources: [.copy("Resources")]),
        .testTarget(name: "HidanCoreTests", dependencies: ["HidanCore"])
    ],
    swiftLanguageModes: [.v5]
)
