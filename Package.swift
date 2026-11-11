// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Agentty",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AgenttyProtocol", targets: ["AgenttyProtocol"]),
        .library(name: "AgenttyClient", targets: ["AgenttyClient"]),
        .library(name: "AgenttyTerminal", targets: ["AgenttyTerminal"]),
        .library(name: "AgenttyHost", targets: ["AgenttyHost"]),
        .executable(name: "agenttyd", targets: ["agenttyd"]),
        .executable(name: "AgenttyMac", targets: ["AgenttyMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // Wire protocol shared by the host daemon and every client (macOS, iOS).
        .target(name: "AgenttyProtocol"),
        // WebSocket client used by the macOS app and, later, the iOS app.
        .target(name: "AgenttyClient", dependencies: ["AgenttyProtocol"]),
        // Terminal emulator view bound to a session, shared by the macOS and iOS apps.
        .target(
            name: "AgenttyTerminal",
            dependencies: ["AgenttyProtocol", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        // macOS only: PTY ownership, session management, WebSocket server.
        .target(name: "AgenttyHost", dependencies: ["AgenttyProtocol"]),
        .executableTarget(name: "agenttyd", dependencies: ["AgenttyHost"]),
        .executableTarget(
            name: "AgenttyMac",
            dependencies: [
                "AgenttyClient",
                "AgenttyHost",
                "AgenttyTerminal",
            ]
        ),
        .testTarget(name: "AgenttyProtocolTests", dependencies: ["AgenttyProtocol"]),
        .testTarget(name: "AgenttyHostTests", dependencies: ["AgenttyHost", "AgenttyClient"]),
    ]
)
