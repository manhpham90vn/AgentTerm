// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentTerm",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AgentTermProtocol", targets: ["AgentTermProtocol"]),
        .library(name: "AgentTermClient", targets: ["AgentTermClient"]),
        .library(name: "AgentTermTerminal", targets: ["AgentTermTerminal"]),
        .library(name: "AgentTermEditor", targets: ["AgentTermEditor"]),
        .library(name: "AgentTermHost", targets: ["AgentTermHost"]),
        .executable(name: "agenttermd", targets: ["agenttermd"]),
        .executable(name: "AgentTermMac", targets: ["AgentTermMac"]),
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
        .target(name: "AgentTermProtocol"),
        // WebSocket client used by the macOS app and, later, the iOS app.
        .target(name: "AgentTermClient", dependencies: ["AgentTermProtocol"]),
        // Terminal emulator view bound to a session, shared by the macOS and iOS apps.
        .target(
            name: "AgentTermTerminal",
            dependencies: ["AgentTermProtocol", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        // Code editor with syntax coloring, Markdown preview and Mermaid
        // diagrams, shared by the macOS and iOS apps.
        .target(
            name: "AgentTermEditor",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            exclude: ["Resources/THIRD-PARTY.md"],
            // Mermaid, to draw diagrams without a network.
            resources: [.copy("Resources/mermaid.min.js")]
        ),
        // Starts a program on a pseudo terminal. C, because it needs fork().
        .target(name: "CAgentTermPTY"),
        // macOS only: PTY ownership, session management, WebSocket server.
        .target(name: "AgentTermHost", dependencies: ["AgentTermProtocol", "CAgentTermPTY"]),
        .executableTarget(name: "agenttermd", dependencies: ["AgentTermHost", "AgentTermClient"]),
        .executableTarget(
            name: "AgentTermMac",
            dependencies: [
                "AgentTermClient",
                "AgentTermEditor",
                "AgentTermHost",
                "AgentTermTerminal",
            ]
        ),
        .testTarget(name: "AgentTermProtocolTests", dependencies: ["AgentTermProtocol"]),
        .testTarget(name: "AgentTermHostTests", dependencies: ["AgentTermHost", "AgentTermClient"]),
    ]
)
