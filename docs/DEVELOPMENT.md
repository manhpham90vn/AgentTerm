# Developing AgentTerm

How to build, run and test AgentTerm from source, and how the code is laid
out. For what the product does see [SPEC.md](SPEC.md), for the architecture
and protocol [DESIGN.md](DESIGN.md), and for releasing [RELEASE.md](RELEASE.md).

## Build and run

`make` lists shortcuts for everything below (`make run`, `make test`,
`make test-ios`, `make release`, ...). The version of both apps is the one
line in the `VERSION` file; `make bump V=0.3.0` changes it.

You need Xcode 16 or later (Swift 5.10+), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) for the iPhone app.

```sh
git clone https://github.com/manhpham90vn/AgentTerm.git
cd AgentTerm
./scripts/run-mac.sh              # build and open the Mac app
```

A build made this way is **AgentTerm Dev**: an app of its own with its own
data, port and pairing links, so it can run next to the released app without
touching its sessions.

```sh
./scripts/run-mac.sh --release        # optimized build
./scripts/run-mac.sh --keep-sessions  # do not restart the daemon
./scripts/bundle-mac.sh               # only build the app bundle in dist/
```

iPhone, in the iOS Simulator:

```sh
brew install xcodegen
./scripts/run-ios.sh              # asks which simulator to use
./scripts/run-ios.sh "iPhone 17"  # or name one (a UDID works too)
./scripts/pair-ios.sh "iPhone 17" # pair it with the app running on this Mac
```

All three in one go, the Mac app, the iPhone app and the pairing:

```sh
./scripts/run-all.sh "iPhone 17"  # or: make run-all SIM="iPhone 17"
```

The simulator has no camera, so `pair-ios.sh` pairs with a link instead of the
QR code. On a real iPhone, run `xcodegen` in `iOS/`, open
`iOS/AgentTerm.xcodeproj`, pick your team under Signing and run.

## Formatting and lint

The code is formatted with [swift-format](https://github.com/swiftlang/swift-format),
which comes with Xcode; its settings are in `.swift-format`.

```sh
make format     # rewrite the Swift files in place
make lint       # report what is off, change nothing; CI runs this and fails on any finding
make check      # lint, build and test
```

## Trying the permission prompts again

`make reset-permissions` takes back every macOS privacy permission given to
AgentTerm Dev (`scripts/reset-macos-permissions.sh --released` includes the
released app), so the prompts and Settings > Permissions can be tried from
the start.

## Tests

```sh
swift test                # protocol, PTY, host server, end to end
./scripts/test-ios.sh     # iPhone UI test against throwaway hosts
```

`test-ios.sh` resets the keychain of the simulator it runs in, so an app
paired there has to pair again.

## How it works

```
 Mac app ─────┐
              ├── WebSocket (JSON + binary frames) ── agenttermd ── PTYs ── claude, codex, agy, copilot
 iPhone app ──┘         127.0.0.1 / Tailscale
```

| Path | What it is |
|---|---|
| `Sources/AgentTermProtocol` | Wire protocol shared by the host and every client |
| `Sources/AgentTermHost` | macOS only: PTYs, sessions, WebSocket server, agent detection, git, usage |
| `Sources/agenttermd` | The host daemon |
| `Sources/AgentTermClient` | WebSocket client for macOS and iOS |
| `Sources/AgentTermTerminal` | Terminal view bound to a session, shared by both apps ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) |
| `Sources/AgentTermEditor` | Text editor and Markdown / Mermaid preview, shared by both apps |
| `Sources/AgentTermTelemetry` | The closed list of events the apps may report, and the user's choices about it; links no service |
| `Sources/AgentTermFirebase` | Firebase behind it, used only by a released build that was given a config file |
| `Sources/AgentTermMac` | The macOS app (SwiftUI) |
| `iOS/` | The iPhone app (SwiftUI) and its UI test; the Xcode project is generated from `project.yml` |
| `scripts/` | Build, run, test and release scripts |
| `packaging/homebrew/` | The Homebrew cask, published to [manhpham90vn/homebrew-tap](https://github.com/manhpham90vn/homebrew-tap) by each release |

## Contributing

Issues and pull requests are welcome. Before opening a pull request, run
`make check` (lint, build and test), and `./scripts/test-ios.sh` if you touched the
iPhone app. Commit messages follow
[Conventional Commits](https://www.conventionalcommits.org).
