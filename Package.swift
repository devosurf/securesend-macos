// swift-tools-version: 6.0
import PackageDescription

// SwiftPM builds the binaries; scripts/build.sh assembles the .app around them.
// SwiftPM has no notion of an application bundle, and the Services registration
// lives entirely in Resources/Info.plist, so the split is the whole story: this
// file resolves dependencies and compiles, that script makes it a Mac app.

let package = Package(
  name: "SecureSend",
  platforms: [.macOS(.v14)],
  targets: [
    // Everything both the app and the development CLIs need.
    .target(name: "SecureSendKit"),

    // The menu bar app. Its executable name is also the Info.plist NSPortName,
    // which is how the system routes a Service request back to this process.
    .executableTarget(name: "SecureSend", dependencies: ["SecureSendKit"]),

    // Development CLIs, not shipped in the bundle.
    .executableTarget(name: "vector", dependencies: ["SecureSendKit"]),
    .executableTarget(name: "preview", dependencies: ["SecureSendKit"]),
    .executableTarget(name: "icon", dependencies: ["SecureSendKit"]),

    // Offline checks on the parts that must agree with packages/crypto byte for
    // byte. Nothing here touches the network.
    .testTarget(
      name: "SecureSendKitTests",
      dependencies: ["SecureSendKit"],
      resources: [.process("Fixtures")]
    ),
  ]
)
