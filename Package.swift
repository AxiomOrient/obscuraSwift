// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ObscuraSwift",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "ObscuraKit", targets: ["ObscuraKit"]),
    .executable(name: "obscura-swift", targets: ["ObscuraCLI"]),
  ],
  targets: [
    .target(
      name: "CObscuraProcess",
      publicHeadersPath: "include",
      cSettings: [.define("_GNU_SOURCE", to: "1")]
    ),
    .target(
      name: "ObscuraKit",
      dependencies: ["CObscuraProcess"]
    ),
    .target(name: "ObscuraCLIArguments"),
    .executableTarget(
      name: "ObscuraCLI",
      dependencies: ["ObscuraKit", "ObscuraCLIArguments"]
    ),
    .testTarget(
      name: "ObscuraKitTests",
      dependencies: ["ObscuraKit"],
      resources: [.copy("Integration/fixture_engine.py")]
    ),
    .testTarget(
      name: "ObscuraCLIArgumentsTests",
      dependencies: ["ObscuraCLIArguments"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
