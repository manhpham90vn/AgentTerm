// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Agentty",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AgenttyProtocol", targets: ["AgenttyProtocol"]),
        .library(name: "AgenttyClient", targets: ["AgenttyClient"]),
        .library(name: "AgenttyTerminal", targets: ["AgenttyTerminal"]),
        .library(name: "AgenttyEditor", targets: ["AgenttyEditor"]),
        .library(name: "AgenttyHost", targets: ["AgenttyHost"]),
        .executable(name: "agenttyd", targets: ["agenttyd"]),
        .executable(name: "AgenttyMac", targets: ["AgenttyMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // Syntax coloring for the file editor (highlight.js).
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.0"),
        // Markdown preview.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
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
        // Code editor with syntax coloring, Markdown preview and Mermaid
        // diagrams, shared by the macOS and iOS apps.
        .target(
            name: "AgenttyEditor",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            exclude: ["Resources/THIRD-PARTY.md"],
            // Mermaid, to draw diagrams without a network.
            resources: [.copy("Resources/mermaid.min.js")]
        ),
        // Starts a program on a pseudo terminal. C, because it needs fork().
        .target(name: "CAgenttyPTY"),
        // macOS only: PTY ownership, session management, WebSocket server.
        .target(name: "AgenttyHost", dependencies: ["AgenttyProtocol", "CAgenttyPTY"]),
        .executableTarget(name: "agenttyd", dependencies: ["AgenttyHost", "AgenttyClient"]),
        .executableTarget(
            name: "AgenttyMac",
            dependencies: [
                "AgenttyClient",
                "AgenttyEditor",
                "AgenttyHost",
                "AgenttyTerminal",
            ]
        ),
        .testTarget(name: "AgenttyProtocolTests", dependencies: ["AgenttyProtocol"]),
        .testTarget(name: "AgenttyHostTests", dependencies: ["AgenttyHost", "AgenttyClient"]),
    ]
)
