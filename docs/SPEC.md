# Agentty product spec

## Summary

Agentty is a native terminal for running coding agents on a Mac and steering
them from an iPhone. The Mac runs the agents in real pseudo terminals. The
iPhone is a remote control for those same terminals: it shows them, resizes
them to fit its screen and sends input.

Agentty is open source under the MIT license.

## Who it is for

Developers who run agent CLIs (Claude Code, Codex, Antigravity, Copilot CLI)
for long tasks and want to check on them, answer a prompt or start a new task
without sitting at the Mac.

## What should make it better than the alternatives

These three are the reasons to pick Agentty, and they take priority when
trading off scope:

1. **A beautiful, easy interface.** Nothing to configure before the first
   session. Starting an agent is one click. The layout is familiar.
2. **Pairing by QR code.** The iPhone scans a code shown by the Mac and is
   connected. No addresses, ports or keys to type.
3. **Vietnamese typing that just works.** Telex and VNI input, with any input
   method, must produce the right text in the shell and inside every agent,
   on the Mac and on the iPhone.

## Platforms

| Platform | Role | Minimum OS |
|---|---|---|
| macOS | Runs the sessions and shows them | macOS 14 |
| iPhone | Remote control for sessions on the Mac | iOS 17 |

iOS does not allow apps to start processes, so the iPhone never runs an agent
itself.

## Features

### Sessions

- A session is one program running in a PTY on the Mac: an agent or a shell.
- Sessions belong to the host daemon, not to a window. Closing the app or
  losing the phone's connection does not stop them.
- Any number of clients can attach to a session and all see the same output.
- A client that attaches gets the recent output replayed so it sees the
  current screen.

### Terminal size

- The terminal resizes to fit the device being used. When the iPhone attaches
  or types, the PTY takes the iPhone's size and the program redraws for it.
- The Mac window then shows the iPhone-sized terminal and says so. Typing on
  the Mac, or pressing "Use This Window's Size", takes the size back.
- On the iPhone, rotating the device, changing the font size and showing or
  hiding the keyboard all resize the terminal.

### Quick launch

- Buttons start Claude Code (`claude`), Codex (`codex`), Antigravity (`agy`),
  Copilot CLI (`copilot`) or a plain shell in the selected folder.
- Agentty detects which CLIs are installed. A CLI that is not installed has no
  button. Detection uses the user's login shell so it matches what a terminal
  would find, and can be re-run without restarting.

### Handoff

Handing off passes the work of one agent's conversation on to another agent.
The typical case: an agent runs out of quota in the middle of a task and
another one should finish it.

- Any conversation can be handed off: a session that is running, or a past one
  in the History tab. The agent that had the conversation does not need to be
  able to answer any more.
- A sheet asks which installed agent should continue; the agent picked last
  time is preselected. It shows the prompt the agent will start with, which
  can be edited and reset, and offers a field for the user's own
  instructions: what to focus on, what to leave alone, anything that is not
  in the conversation. The instructions are optional and are added after the
  prompt.
- Agentty writes a handoff file into the project with the conversation so far
  (what the user and the agent said, without tool output) and the state of the
  working tree, then starts the receiving agent in a new session with a prompt
  to read that file and continue.
- Handoff files live in `.agentty/handoffs/` and are kept out of git through
  the repository's local exclude file. The project's `.gitignore` is not
  changed.
- The original session and conversation are left as they are.

### macOS window

Three panes, like a code editor:

- **Left: folders.** Project folders the user added, each with its running
  sessions underneath. The list belongs to the host, so the iPhone shows the
  same folders. Sessions started elsewhere are listed under "Other".
- **Middle: terminal.** The selected session. With no session selected, a
  launch screen for the selected folder.
- **Right: side panel**, with two tabs. The panel can be hidden.
  - **Git.** Uncommitted git changes of the selected folder: the changed files
    with added and removed line counts, and the diff of the selected file. An
    icon switches the file list between a flat list and a tree grouped by
    folder; folders in the tree can be collapsed and show the totals of what
    is inside. It refreshes on its own while the app is in front.
  - **History.** The conversations each agent had in the selected folder, one
    section per agent, newest first, with a title and how
    long ago it was. A conversation can be resumed, which opens it in its
    agent in a new session, or handed off to another agent. Like the Git
    tab it covers the selected folder only: conversations that ran in a
    subfolder belong to that subfolder. A switch at the top changes the list
    to **All**: every conversation on the Mac, each row naming its folder.

### Pairing and remote access

- The Mac shows a QR code containing its Tailscale name, the port and a
  pairing token. The iPhone scans it once and remembers the Mac.
- All remote traffic goes through Tailscale. Agentty does not run a relay
  server and does not open a port on the local network.
- If Tailscale is not connected on the Mac, the pairing screen says so and
  explains what to do.

### iPhone app

- List of sessions on the paired Mac, with the folder each runs in.
- Full terminal for a session, sized to the screen.
- A key bar above the keyboard for keys a phone keyboard lacks: Esc, Tab,
  Shift+Tab, Ctrl, arrows, and Enter.
- A compose field for writing a prompt with the normal iOS keyboard,
  autocorrect and input methods, sent to the terminal in one go.
- Quick launch for the installed agents, in any folder known to the Mac.
- Text size can be changed, which changes how many columns fit.
- When the connection drops, the app reconnects on its own and returns to the
  session that was open.
- A read-only view of a folder's changes (not built yet).

### Notifications (later)

When an agent finishes or waits for an answer, the iPhone is notified. This
needs a push provider and is not part of the first release.

## Vietnamese input requirements

- The host forces a UTF-8 locale for every session.
- Input bytes travel unchanged from the client to the PTY.
- macOS: composition with the built-in Telex and VNI input methods shows the
  text being composed at the cursor and commits the final text only.
  Third-party tools that retype text with backspaces (EVKey, OpenKey,
  GoTiengViet) must also give the right result.
- iPhone: the compose field is the default way to type prose, so composition
  never happens inside the terminal emulator.
- Each release is checked against a matrix: {built-in Telex, built-in VNI,
  EVKey or OpenKey} × {zsh, Claude Code, Codex, Antigravity, Copilot CLI}.

## Out of scope

- Running agents on the iPhone or on a server Agentty hosts.
- Remote access without Tailscale.
- A code editor. The changes pane is read-only.
- Windows and Linux hosts.

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| M1 Mac core | Host daemon, PTY sessions, protocol, macOS three-pane app, agent detection and quick launch, changes pane, pairing QR code | Done, except the Vietnamese input matrix, which is checked by hand and not yet run |
| M2 iPhone | iOS app: scan to pair, session list, terminal sized to the phone, key bar, compose field | Works in the iOS Simulator. Not yet run on a real iPhone, so QR scanning with the camera, Tailscale from the phone and typing with the Vietnamese keyboard are unverified |
| M3 Polish | Host as a login item, screen snapshot on attach, changes pane on iPhone, app icon, signed and notarized Mac build | Not started |
| M4 Awareness | Agent state (working, waiting, done) and notifications | Not started |
