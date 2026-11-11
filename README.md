# AgentTerm

A native macOS terminal for coding agents, with an iPhone remote.

AgentTerm runs Claude Code, Codex, Antigravity (`agy`) and GitHub Copilot CLI in
real terminals on your Mac. A small host daemon owns the terminals, so the
sessions keep running when the window is closed, and other devices can attach
to the same sessions over [Tailscale](https://tailscale.com).

> Status: early. The macOS app, the host daemon and a first iPhone app work.
> The iPhone app has only been run in the iOS Simulator so far. See
> [docs/SPEC.md](docs/SPEC.md) for the plan and what is done.

## What works today

- Three-pane window: project folders on the left, the terminal in the middle,
  the folder's uncommitted git changes on the right, to stage, unstage and
  commit.
- One-click launch for each agent CLI that is installed. AgentTerm looks them up
  through your login shell, so anything on your normal `PATH` is found, and
  agents that are not installed get no button.
- Files: browse the folder, create, rename and trash files and folders. Files
  open as tabs next to the sessions, to edit text with syntax coloring and
  preview Markdown, Mermaid diagrams included. The iPhone app has the same.
- A usage line under each agent's terminal: model, context, and what the
  account has left with reset times, as the agent's own `/usage` or `/status`
  shows it, for Claude Code, Codex, Antigravity and Copilot CLI. To ask the
  agents' services, AgentTerm reads each agent's sign-in on your Mac and sends
  it only to the service that issued it; `agenttermd --no-account-usage` turns
  that off.
- Stays in the menu bar when its window is closed, if you want it to.
- Real PTYs: job control, Ctrl-C, colors, resize, UTF-8 (Vietnamese included).
- Sessions live in the `agenttermd` daemon and survive closing the app.
- A session can be watched from several clients. The client being used decides
  the terminal size; the others follow.
- iPhone app: pair by scanning the Mac's QR code, see the Mac's folders and
  sessions, start an agent in any folder on the Mac, and use a terminal sized
  to the phone, with a key bar (Esc, Tab, Shift+Tab, Ctrl-C, arrows) and a
  compose field for writing prompts with the normal iOS keyboard. It also
  shows a folder's git changes and conversation history, and can resume a
  conversation or hand it off to another agent.
- Handoff: pass a conversation's work to another agent, for when one runs
  out of quota. The other agent gets the conversation so far and the state of
  the working tree.

## Requirements

- macOS 14 or later
- iOS 17 or later for the iPhone app
- Xcode 16 or later (Swift 5.10+) to build, and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the iPhone app
- Tailscale on the Mac and the iPhone, for remote access

## Build and run

macOS:

```sh
./scripts/run-mac.sh              # build, then open dist/AgentTerm.app
./scripts/run-mac.sh --release    # optimized build
./scripts/bundle-mac.sh           # only build dist/AgentTerm.app
```

`run-mac.sh` restarts the host daemon so the new build is used, which ends
running sessions. Pass `--keep-sessions` to leave it alone.

iPhone, in the iOS Simulator:

```sh
brew install xcodegen
./scripts/run-ios.sh              # asks which simulator to use
./scripts/run-ios.sh "iPhone 17"  # or name one (a UDID works too)
./scripts/run-ios.sh --list       # show the simulators
./scripts/pair-ios.sh "iPhone 17" # pair it with AgentTerm running on this Mac
```

The simulator has no camera, so `pair-ios.sh` pairs it with a link instead of
the QR code. `SIMULATOR="iPhone 17"` in the environment works for every iOS
script. On a real iPhone, run `xcodegen` in `iOS/`, open
`iOS/AgentTerm.xcodeproj`, pick your team under Signing and run.

Tests:

```sh
swift test                # protocol, PTY, host server, end to end
./scripts/test-ios.sh     # iPhone UI test against throwaway hosts; resets
                          # the chosen simulator's keychain
```

## Layout

| Path | What it is |
|---|---|
| `Sources/AgentTermProtocol` | Wire protocol shared by the host and every client |
| `Sources/AgentTermHost` | macOS only: PTYs, sessions, WebSocket server, agent detection, git diff |
| `Sources/agenttermd` | The host daemon |
| `Sources/AgentTermClient` | WebSocket client for macOS and iOS |
| `Sources/AgentTermTerminal` | Terminal view bound to a session, shared by both apps ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) |
| `Sources/AgentTermMac` | The macOS app (SwiftUI) |
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
- The Mac's own token (`~/Library/Application Support/AgentTerm/token`) is only
  accepted from the Mac itself.

## License

MIT. See [LICENSE](LICENSE).

## Releasing

See [docs/RELEASE.md](docs/RELEASE.md): TestFlight for the iPhone app, a notarized disk image for the Mac app.
