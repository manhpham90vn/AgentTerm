# Agentty

A native macOS terminal for coding agents, with an iPhone remote.

Agentty runs Claude Code, Codex, Antigravity (`agy`) and GitHub Copilot CLI in
real terminals on your Mac. A small host daemon owns the terminals, so the
sessions keep running when the window is closed, and other devices can attach
to the same sessions over [Tailscale](https://tailscale.com).

> Status: early. The macOS app, the host daemon and a first iPhone app work.
> The iPhone app has only been run in the iOS Simulator so far. See
> [docs/SPEC.md](docs/SPEC.md) for the plan and what is done.

## What works today

- Three-pane window: project folders on the left, the terminal in the middle,
  the folder's uncommitted git changes on the right.
- One-click launch for each agent CLI that is installed. Agentty looks them up
  through your login shell, so anything on your normal `PATH` is found, and
  agents that are not installed get no button.
- Real PTYs: job control, Ctrl-C, colors, resize, UTF-8 (Vietnamese included).
- Sessions live in the `agenttyd` daemon and survive closing the app.
- A session can be watched from several clients. The client being used decides
  the terminal size; the others follow.
- iPhone app: pair by scanning the Mac's QR code, see the Mac's folders and
  sessions, start an agent, and use a terminal sized to the phone, with a key
  bar (Esc, Tab, Shift+Tab, Ctrl-C, arrows) and a compose field for writing
  prompts with the normal iOS keyboard.

## Requirements

- macOS 14 or later
- iOS 17 or later for the iPhone app
- Xcode 16 or later (Swift 5.10+) to build, and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the iPhone app
- Tailscale on the Mac and the iPhone, for remote access

## Build and run

macOS:

```sh
./scripts/run-mac.sh              # build, then open dist/Agentty.app
./scripts/run-mac.sh --release    # optimized build
./scripts/bundle-mac.sh           # only build dist/Agentty.app
```

`run-mac.sh` restarts the host daemon so the new build is used, which ends
running sessions. Pass `--keep-sessions` to leave it alone.

iPhone, in the iOS Simulator:

```sh
brew install xcodegen
./scripts/run-ios.sh              # the booted simulator, or "iPhone 17"
```

The simulator has no camera, so pair it with a link instead of the QR code:
`./scripts/pair-ios.sh`, with Agentty open on the Mac. On a real iPhone, run `xcodegen` in `iOS/`, open
`iOS/Agentty.xcodeproj`, pick your team under Signing and run.

Tests:

```sh
swift test                # protocol, PTY, host server, end to end
./scripts/test-ios.sh     # iPhone UI test against a throwaway host
```

## Layout

| Path | What it is |
|---|---|
| `Sources/AgenttyProtocol` | Wire protocol shared by the host and every client |
| `Sources/AgenttyHost` | macOS only: PTYs, sessions, WebSocket server, agent detection, git diff |
| `Sources/agenttyd` | The host daemon |
| `Sources/AgenttyClient` | WebSocket client for macOS and iOS |
| `Sources/AgenttyTerminal` | Terminal view bound to a session, shared by both apps ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) |
| `Sources/AgenttyMac` | The macOS app (SwiftUI) |
| `iOS/` | The iPhone app (SwiftUI) and its UI test; the Xcode project is generated from `project.yml` |
| `scripts/` | Build, run and test scripts |
| `docs/SPEC.md` | Product spec and roadmap |
| `docs/DESIGN.md` | Architecture, protocol and design decisions |

## Security

The host daemon gives shell access, so it is careful about who connects:

- It listens only on `127.0.0.1` and on the Mac's Tailscale address, never on
  the local network.
- An iPhone pairs with a code that works once and for five minutes, and only
  while the pairing screen is open. Pairing gives the phone a token of its
  own, which the Mac can revoke under "Pair iPhone".
- The Mac's own token (`~/Library/Application Support/Agentty/token`) is only
  accepted from the Mac itself.

## License

MIT. See [LICENSE](LICENSE).
