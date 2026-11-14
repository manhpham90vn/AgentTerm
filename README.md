<div align="center">

# AgentTerm

**A native Mac terminal for AI agents, with built-in MCP tools and an iPhone remote.**

Run Claude Code, Codex, Antigravity and GitHub Copilot CLI on your Mac.
Give them visible shells to work in, and steer the same sessions from your iPhone.

[![CI](https://github.com/manhpham90vn/AgentTerm/actions/workflows/ci.yml/badge.svg)](https://github.com/manhpham90vn/AgentTerm/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/manhpham90vn/AgentTerm?include_prereleases&label=release)](https://github.com/manhpham90vn/AgentTerm/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-lightgrey)
[![Discord](https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white)](https://discord.gg/Ksagmsd6j)

<img src="docs/screenshots/mac.png" alt="AgentTerm on macOS: folders, an agent's terminal and the git panel" width="900">

</div>

AgentTerm runs each agent in a real terminal owned by a small host daemon, so
sessions keep running when the window is closed and your iPhone can attach to
them over [Tailscale](https://tailscale.com).

> **Status: beta.** Use matching versions of the Mac and iPhone apps; see [Compatibility](#compatibility).

## Product direction

AgentTerm puts the agent at the center of the workflow. You give it a task;
it uses tools to observe, act and check the result. AgentTerm provides the
working environment and lets you follow the work, answer questions, review
results and take over from your Mac or iPhone.

- **The Mac runs the work.** Agents, shells and the planned embedded browser
  run on the Mac. Terminal sessions belong to the host daemon and keep
  running when the app window closes.
- **MCP connects agents to the environment.** The built-in Model Context
  Protocol server already lets agents open visible shell tabs, run commands
  and read their output. Browser tools will extend this to websites and web
  apps, with explicit actions and observable results.
- **Shells and a browser are the agent's tools.** Shells provide access to
  code, Git, tests and development servers. The planned browser will let
  agents read pages, fill forms, use web services and test interfaces, while
  remaining useful for a person browsing directly.
- **The iPhone keeps you involved away from the desk.** It controls the
  sessions running on your Mac: start work, check progress, answer an agent
  and review changes. The agent does not run on the phone.
- **People and agents share visible work.** Make it clear which agent owns
  a shell or controls a browser tab. Let the user inspect the work and take
  control without competing input. Keep tools predictable, report failures
  clearly and show unknown state as unknown.

### Plug-and-play extensibility

The product is being designed so new capabilities can be added through
MCP servers and plugins. Shells and the planned browser are the first tools
in an environment that can grow with the work people give their agents.

- **Connect more tools through MCP.** Developers should be able to create
  and connect additional MCP servers for services, data and specialized
  workflows, alongside AgentTerm's built-in server.
- **Extend the workspace through plugins.** Plugins should be able to add
  agent integrations, panels, commands and other capabilities without
  requiring a custom build of AgentTerm.
- **Make extensions easy to manage.** Installation, configuration, enabling,
  disabling and removal should be clear. Each extension should declare what
  it provides and what access it needs, report failures visibly and follow
  the same session ownership rules as the built-in tools.
- **Keep the Mac and iPhone connected.** Extensions run through the Mac
  host. Their everyday actions and results should be available on the phone
  wherever the device allows, with clear limits for features that need the
  Mac interface.

This is the extension direction, not a shipped plugin API. The built-in
shell MCP server exists today; management of additional servers and the
plugin interfaces still need to be defined. The
[plugin work](https://github.com/manhpham90vn/AgentTerm/issues/12) remains
in the backlog, separate from the 0.8.0 milestone.

### Next: 0.8.0

The [0.8.0 milestone](https://github.com/manhpham90vn/AgentTerm/milestone/8)
develops this direction through an attention inbox, split panes, a prompt
composer, feedback on diffs, queued instructions, richer handoffs and results,
PR and CI review, worktree setup, delegation and comparisons across agents.

The [embedded browser](https://github.com/manhpham90vn/AgentTerm/issues/76)
is planned for this release. It will combine everyday browsing with tools
for agents to inspect pages, navigate, interact and verify outcomes in the
same visible workspace. Its engine, profile boundaries and presentation on
the iPhone still need to be decided.

[Apple push notifications](https://github.com/manhpham90vn/AgentTerm/issues/66)
are also planned so the iPhone can notify you when an agent needs you even
while the app is suspended. The delivery infrastructure remains to be
researched. The current app has neither Apple push nor an embedded browser.

Release scope and decisions are tracked in the
[roadmap](https://github.com/manhpham90vn/AgentTerm/issues/28).

## Features

- **Every agent, one click.** Starts any agent CLI installed on your Mac, in a
  real terminal.
- **Sessions that keep running.** Close the window or quit the app; they are
  still there, and the app can stay in the menu bar.
- **Built-in MCP server.** Agents can open shell tabs you can see, send
  commands and read their output. The user can interact with those shells
  from the Mac or iPhone.
- **Tabs you arrange.** Sessions, files and diffs in one strip: drag to
  reorder, pin, and group with a name and a color.
- **Git, files and history** of each project folder next to the terminal:
  stage, commit, push and pull, have an agent write the commit message, edit
  files, preview Markdown and Mermaid, resume a past conversation.
- **Usage at a glance.** Model, context and what your account has left, with
  reset times, for Claude Code, Codex, Antigravity and Copilot CLI, and how
  the Mac itself is doing:
  processor, memory, network speed, temperature, battery and uptime.
- **SSH hosts.** The hosts of your `~/.ssh/config`, one click each, also
  from the iPhone through the Mac.
- **Handoff.** Pass a conversation's work to another agent when one runs out
  of quota, in the same folder or another one.
- **iPhone remote.** Pair with a QR code and get the same sessions, folders,
  git, files and usage on your phone, with a key bar and a compose field made
  for prompts. Pins, groups and order stay in sync with the Mac.

<p>
<img src="fastlane/screenshots/en-US/01-sessions.png" alt="Sessions on iPhone" width="200">
<img src="fastlane/screenshots/en-US/02-terminal.png" alt="Terminal on iPhone" width="200">
<img src="fastlane/screenshots/en-US/04-git.png" alt="Git changes on iPhone" width="200">
<img src="fastlane/screenshots/en-US/06-files.png" alt="Files on iPhone" width="200">
</p>

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
3. Click **Pair Device**, and scan the code with the iPhone app.

macOS asks for permissions on behalf of what the agents do (files, automation,
screen recording and so on). **Settings → Permissions** lists them and where to
grant each.

## Compatibility

The Mac and iPhone apps talk over a versioned protocol, so use versions from
the same row.

| Mac app | iPhone app | Protocol |
|---|---|---|
| 0.6.x | 0.6.x | 7 |
| 0.4.x, 0.5.x | 0.4.x, 0.5.x | 6 |
| 0.2.x, 0.3.x | 0.2.x, 0.3.x | 5 |
| 0.1.x | 0.1.x | 4 |

Versions from different rows are not supported together. Update both apps
when you update one.

## Security and privacy

The daemon listens only on `127.0.0.1` and the Mac's Tailscale address. An
iPhone pairs with a one-time code and gets a token of its own, which the Mac
can revoke. To show account usage, AgentTerm reads each agent's sign-in on
your Mac and sends it only to the service that issued it
(`agenttermd --no-account-usage` turns that off).

The released apps can send crash reports and counts of which features are
used through Firebase, each with a switch shown at the first launch, and
nothing before that screen is answered; never terminal content, prompts,
file names or folders. A build from source sends
nothing. AgentTerm has no server of its own. Details
in [SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md).

## Documentation

- [docs/SPEC.md](docs/SPEC.md): everything the product does
- [Issues](https://github.com/manhpham90vn/AgentTerm/issues): planned work and known bugs
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): build from source, tests, code layout, contributing
- [docs/DESIGN.md](docs/DESIGN.md): architecture and protocol
- [docs/RELEASE.md](docs/RELEASE.md): how releases are made
- [SUPPORT.md](SUPPORT.md): getting help
- [Discord](https://discord.gg/Ksagmsd6j): questions, ideas and news

## License

[MIT](LICENSE). Third-party software is listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
