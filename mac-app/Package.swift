// swift-tools-version:5.9
import PackageDescription

// Native menu-bar app that replaces the old Python `bridge/`. It reads the
// local Claude Code / Codex CLI session logs and serves a /status JSON endpoint
// the ESP8266 clock polls. Uses only system frameworks (AppKit, Network,
// Foundation, IOKit) so there are no dependencies to fetch or vendor.
let package = Package(
    name: "AIClockBridge",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "AIClockBridge",
            path: "Sources/AIClockBridge",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AIClockBridgeTests",
            dependencies: ["AIClockBridge"],
            path: "Tests/AIClockBridgeTests"
        ),
    ]
)
