<div align="center">

# AgentTerm

**A native macOS terminal for coding agents, with an iPhone remote.**

Run Claude Code, Codex, Antigravity and GitHub Copilot CLI side by side on your Mac,
and pick up any session from your iPhone.

[![CI](https://github.com/manhpham90vn/AgentTerm/actions/workflows/ci.yml/badge.svg)](https://github.com/manhpham90vn/AgentTerm/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/manhpham90vn/AgentTerm?include_prereleases&label=release)](https://github.com/manhpham90vn/AgentTerm/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-lightgrey)

<img src="docs/screenshots/mac.png" alt="AgentTerm on macOS: folders, an agent's terminal and the git panel" width="900">

</div>

## Overview

AgentTerm runs each agent in a real terminal owned by a small host daemon,
`agenttermd`. Because the daemon owns the terminals, sessions keep running
when the window is closed, and other devices can attach to the same sessions
over [Tailscale](https://tailscale.com). Around the terminal it adds what
working with agents needs: the folder's git changes, its files, each agent's
conversation history and how much of your quota is left.

> **Status: beta.** The Mac app is distributed as a notarized disk image and
> the iPhone app through TestFlight. Both apps of a release must be used
> together; the two speak a versioned protocol.

## Features

### Sessions

- One click starts any agent CLI that is installed. AgentTerm finds them
  through your login shell, so whatever is on your `PATH` works, and an agent
  that is not installed gets no button.
- Real PTYs: job control, Ctrl-C, colors, resize and UTF-8, Vietnamese input
  included.
- Sessions live in the daemon. Close the window, quit the app, come back: they
  are still there. The app can stay in the menu bar.
- Several clients can watch one session. The one in use decides the terminal
  size and the others follow.

### Workspace

- **Tabs.** Sessions, open files and diffs share one tab strip. Drag tabs to
  reorder them, pin the ones you keep, and put related tabs in named, colored
  groups that fold away.
- **Folders.** Project folders with their sessions underneath. Reorder them
  by dragging, or drop a folder in from the Finder.
- **Git.** Staged and unstaged changes of the folder, with diffs, staging and
  commit.
- **Files.** Browse, create, rename and trash. Edit text with syntax coloring
  and preview Markdown, Mermaid diagrams included.
- **History.** Every conversation each agent had in a folder, to resume or to
  hand off.

### Agents

- **Usage.** A band under each agent's terminal shows the model, how full the
  context is, and what your account has left with reset times, as the agent's
  own `/usage` or `/status` reports it. Supported for Claude Code, Codex,
  Antigravity and Copilot CLI.
- **Handoff.** Pass a conversation's work to another agent, for when one runs
  out of quota. The other agent gets the conversation so far and the state of
  the working tree, and can continue in the same folder or another one.

### iPhone

<p>
<img src="fastlane/screenshots/en-US/01-sessions.png" alt="Sessions on iPhone" width="200">
<img src="fastlane/screenshots/en-US/02-terminal.png" alt="Terminal on iPhone" width="200">
<img src="fastlane/screenshots/en-US/04-git.png" alt="Git changes on iPhone" width="200">
<img src="fastlane/screenshots/en-US/06-files.png" alt="Files on iPhone" width="200">
</p>

- Pair by scanning a QR code on the Mac. More than one Mac can be paired.
- A terminal sized to the phone, with a key bar (Esc, Tab, Shift+Tab, Ctrl-C,
  arrows) and a compose field for writing prompts with the normal keyboard.
- The same folders, git changes, files, history, usage and handoff as the Mac.
- Pins, groups and the order of sessions and folders are kept by the host, so
  a change on one device appears on the other.

## Install

**Mac, with [Homebrew](https://brew.sh):**

```sh
brew tap manhpham90vn/tap
brew trust manhpham90vn/tap     # Homebrew 7 and later: a tap outside Homebrew's own has to be trusted first
brew install --cask agentterm
```

`brew upgrade --cask agentterm` gets a newer version later.

**Mac, by hand:** download the latest `AgentTerm-<version>.dmg` from
[Releases](https://github.com/manhpham90vn/AgentTerm/releases), open it and
drag AgentTerm to Applications.

Either way the app is signed and notarized. It is built for Apple silicon.

**iPhone:** [join the beta on TestFlight](https://testflight.apple.com/join/Ny2JKHUp).

Requirements: macOS 14 or later, iOS 17 or later, and
[Tailscale](https://tailscale.com) on both devices to reach the Mac from
outside your desk. At least one agent CLI installed on the Mac.

### Getting started

1. Open AgentTerm on the Mac and add a project folder.
2. Start an agent with its button in the toolbar.
3. Click **Pair iPhone**, and scan the code with the iPhone app.

macOS asks for permissions on behalf of what the agents do (files, automation,
screen recording and so on). **Settings → Permissions** lists them and where to
grant each.

## Build from source

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

The simulator has no camera, so `pair-ios.sh` pairs with a link instead of the
QR code. On a real iPhone, run `xcodegen` in `iOS/`, open
`iOS/AgentTerm.xcodeproj`, pick your team under Signing and run.

### Tests

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
| `Sources/AgentTermMac` | The macOS app (SwiftUI) |
| `iOS/` | The iPhone app (SwiftUI) and its UI test; the Xcode project is generated from `project.yml` |
| `scripts/` | Build, run, test and release scripts |
| `packaging/homebrew/` | The Homebrew cask, published to [manhpham90vn/homebrew-tap](https://github.com/manhpham90vn/homebrew-tap) by each release |

## Security and privacy

The host daemon gives shell access, so it is careful about who connects:

- It listens only on `127.0.0.1` and on the Mac's Tailscale address, never on
  the local network.
- An iPhone pairs with a code that works once and for five minutes, and only
  while the pairing screen is open. Pairing gives the phone a token of its
  own, which the Mac can revoke under **Pair iPhone**.
- The Mac's own token is only accepted from the Mac itself.

To show account usage, AgentTerm reads each agent's sign-in on your Mac and
sends it only to the service that issued it. `agenttermd --no-account-usage`
turns that off. AgentTerm has no server of its own and collects nothing. See
[PRIVACY.md](PRIVACY.md).

## Documentation

- [docs/SPEC.md](docs/SPEC.md): what the product does, in detail, and the roadmap
- [docs/DESIGN.md](docs/DESIGN.md): architecture, protocol and design decisions
- [docs/RELEASE.md](docs/RELEASE.md): how releases are built, signed and published
- [SUPPORT.md](SUPPORT.md): getting help

## Contributing

Issues and pull requests are welcome. Before opening a pull request, run
`swift build` and `swift test`, and `./scripts/test-ios.sh` if you touched the
iPhone app. Commit messages follow
[Conventional Commits](https://www.conventionalcommits.org).

## License

[MIT](LICENSE)
