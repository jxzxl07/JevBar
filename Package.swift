// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "JevBar",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "JevBar",
      path: "Sources/JevBar",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(name: "JevBarTests", dependencies: ["JevBar"], path: "Tests/JevBarTests"),
  ]
)
