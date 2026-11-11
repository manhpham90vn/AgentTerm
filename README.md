# Agentty

A native macOS terminal for coding agents, with an iPhone remote on the way.

Agentty runs Claude Code, Codex, Antigravity (`agy`) and GitHub Copilot CLI in
real terminals on your Mac. A small host daemon owns the terminals, so the
sessions keep running when the window is closed, and other devices can attach
to the same sessions over [Tailscale](https://tailscale.com).

> Status: early. The macOS app and the host daemon work. The iPhone app is not
> written yet. See [docs/SPEC.md](docs/SPEC.md) for the plan and what is done.

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
- A pairing QR code for the upcoming iPhone app.

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 5.10+) to build
- Tailscale on the Mac and the iPhone, for remote access

## Build and run

```sh
swift build
swift run AgenttyMac          # starts agenttyd next to it when needed

./scripts/bundle-mac.sh       # or build dist/Agentty.app
open dist/Agentty.app
```

Run the tests with `swift test`.

## Layout

| Path | What it is |
|---|---|
| `Sources/AgenttyProtocol` | Wire protocol shared by the host and every client |
| `Sources/AgenttyHost` | macOS only: PTYs, sessions, WebSocket server, agent detection, git diff |
| `Sources/agenttyd` | The host daemon |
| `Sources/AgenttyClient` | WebSocket client for macOS and iOS |
| `Sources/AgenttyMac` | The macOS app (SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) |
| `docs/SPEC.md` | Product spec and roadmap |
| `docs/DESIGN.md` | Architecture, protocol and design decisions |

## Security

The daemon gives shell access to whoever holds the pairing token. It listens
only on `127.0.0.1` and on the Mac's Tailscale address, never on the local
network. The token is stored in `~/Library/Application Support/Agentty/token`,
readable by you only. Treat the pairing QR code like a password.

## License

MIT. See [LICENSE](LICENSE).
