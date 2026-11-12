# AgentTerm product spec

## Summary

AgentTerm is a native terminal for running coding agents on a Mac and steering
them from an iPhone. The Mac runs the agents in real pseudo terminals. The
iPhone is a remote control for those same terminals: it shows them, resizes
them to fit its screen and sends input.

AgentTerm is open source under the MIT license.

## Who it is for

Developers who run agent CLIs (Claude Code, Codex, Antigravity, Copilot CLI)
for long tasks and want to check on them, answer a prompt or start a new task
without sitting at the Mac.

## What should make it better than the alternatives

These three are the reasons to pick AgentTerm, and they take priority when
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

### Session names

- A session is named after what it is about: the title of the conversation
  its agent is having, the same title the History tab shows.
- Until the agent has saved a conversation the session keeps the agent's
  name ("Claude Code"), and it changes by itself once there is one. A shell
  keeps the shell's name.
- The name and the agent's icon are the same on the Mac (folder list and
  tabs) and on the iPhone.

### Usage

Under an agent's terminal, on the Mac and on the iPhone, a band shows the
few figures worth a glance: the model, how full the context is, and what the
account's main limits have left, each in a cell of its own with a small bar
(and, on the Mac, when it starts over). As many cells are shown as fit.
Clicking the band opens everything the agent's own usage screen shows.

| Agent | What is shown, as `/usage` or `/status` shows it |
|---|---|
| Claude Code | Current session, current week (all models), current week per model, each as "% used" with its reset time. The plan, extra usage, and banked limit resets where Anthropic reports them (it does not to Claude Code's own sign-in on every account). Context with its share of the window |
| Codex | 5h limit and weekly limit, each as "% left" with its reset time. The plan, banked limit resets and when the first expires, credits. Context with its share of the window |
| Antigravity | Each group of models (Gemini, Claude and GPT, and any separate quota such as Gemini 4 Argon) with its weekly and five-hour limit, as "% left" with reset times. The plan. Context tokens |
| Copilot CLI | Premium requests left of the month's allowance, with the reset date. The plan. Context with its share of the window |

Every agent's band has the same cells in the same order: the model, the
context, then the limits, the short one before the week. A figure that is
not known yet shows as a dash. Before a session's first reply the model is
the one the agent's settings name (Codex, Antigravity) or the one it
reports (Claude Code); Copilot CLI names its model only after its first
reply.

A limit turns amber at 70% used and red at 90%. The session's figures update
every few seconds, the account's every five minutes while the agent has a
session, and on request.

Where the figures come from:

- **The account's limits** come from the agent's own service: Anthropic,
  ChatGPT, Google, GitHub. The request needs the agent's sign-in, which
  AgentTerm reads where the agent keeps it on this Mac (the login keychain for
  Claude Code and Antigravity, `~/.codex/auth.json` for Codex, `gh` for
  Copilot). It is used for that request, sent only to the service that
  issued it, never renewed, saved, logged or sent to an iPhone. When a
  sign-in has run out, the line says so and the agent renews it itself with
  its next message. `agenttermd --no-account-usage` turns all of this off.
- **The context** comes from what the agent records on this Mac. Claude
  Code also reports it, with its limits, to its status line: sessions
  AgentTerm starts get a status line command of AgentTerm's own for that, which
  then runs the status line the user had set up, so theirs still shows. For
  someone without one, Claude Code hides some of its keyboard hints once any
  status line is set, which is Claude Code's doing.

These are the services' own endpoints for their own apps, not public APIs,
and may change without notice. A figure that cannot be read is left out
rather than guessed.

### Terminal size

- The terminal resizes to fit the device being used. Opening a session on the
  iPhone, or typing in it there, gives the PTY the iPhone's size and the
  program redraws for it.
- A device that only shows a session never changes its size. The Mac app
  lists and shows every session, including the ones a phone is typing in; it
  takes a session's size only when the user types in it on the Mac or presses
  "Use This Window's Size".
- While another device is using a session, the Mac shows that device's
  terminal centered in a frame, like a preview of its screen, with a line
  above saying so. This is the same for shells and for agents.
- The other way round, while the Mac is using a session that is open on the
  iPhone, the iPhone shows the Mac's whole terminal scaled down to fit, with a
  line saying so and a "Fit This Screen" button that takes the session back.
- Handing a session back and forth redraws the program for the new size each
  time.
- What a terminal sends by itself (answers to the program's questions, focus
  changes, the pointer passing over the window) is not use of the session and
  never changes its size.
- On the iPhone, rotating the device, changing the font size and showing or
  hiding the keyboard all resize the terminal.

### Quick launch

- Buttons start Claude Code (`claude`), Codex (`codex`), Antigravity (`agy`),
  Copilot CLI (`copilot`) or a plain shell in the selected folder.
- AgentTerm detects which CLIs are installed. A CLI that is not installed has no
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
- AgentTerm writes a handoff file into the project with the conversation so far
  (what the user and the agent said, without tool output) and the state of the
  working tree, then starts the receiving agent in a new session with a prompt
  to read that file and continue.
- Handoff files live in `.agentterm/handoffs/` and are kept out of git through
  the repository's local exclude file. The project's `.gitignore` is not
  changed.
- The original session and conversation are left as they are.

A handoff can also move the work to another folder: the sheet's **Continue
in** lists the folders of the Mac's list, the conversation's own first. The
handoff file is then written in the folder chosen, the receiving agent
starts there, and the file says which folder the conversation happened in.
In another folder the same agent can be picked too, which carries a
conversation over to a neighbouring project.

### macOS window

Three panes, like a code editor. The toolbar follows them: the button that
hides the folder list is at the far left, the launch buttons for the agents
are in the middle, followed by the pairing button, which is filled so it
stands out, and in the far right corner is the button that hides the side
panel.

- **Left: folders.** A Settings button sits in the bottom left corner. Project folders the user added, each with its running
  sessions underneath. A session shows its agent's icon and a name. The list belongs to the host, so the iPhone shows the
  same folders. Sessions started elsewhere are listed under "Other".
  A folder is dragged onto another to go before it, or moved up and down
  from its menu; a folder dragged in from the Finder is added. A folder's
  sessions are in the order of their tabs and can be dragged the same way.
- **Middle: terminal.** The selected session. With no session selected, a
  launch screen for the selected folder. Above it, every running session is a
  tab, with a "+" to start another. Command and a number (⌘1 to ⌘9) shows the
  tab in that place, ⌘⇧] and ⌘⇧[ go to the next and previous, ⌘W ends the
  session on screen. Open files are tabs in the same strip, and so is the
  diff picked in the Git tab. A tab's menu (right click) closes it, the
  other tabs, every file (terminals stay), or every tab. Whatever would end
  a session asks first. Files with unsaved changes are never closed
  without asking.
  Tabs are arranged by hand. A tab is dragged onto another to go before it
  (or moved from its menu and the Tab menu). A **pinned** tab stays first
  and is left open by the commands that close many tabs. Tabs can be put
  in a **group**, which has a name and a color and shows as a label before
  its tabs; clicking the label folds the group away. A tab takes on the
  place it is dropped in: pinned among the pinned, in the group of the tab
  it lands next to, or on a group's label to join it.
- **Right: side panel**, with three tabs. The panel can be hidden.
  - **Git.** Uncommitted git changes of the selected folder: the changed files
    with added and removed line counts. Clicking a file shows its diff in the
    middle pane, in one diff tab that follows the file picked. An
    icon switches the file list between a flat list and a tree grouped by
    folder; folders in the tree can be collapsed and show the totals of what
    is inside. It refreshes on its own while the app is in front.
    The files are in two lists, **Staged** and **Changes**. A button on a
    file moves it to the other list, a button on a list's title moves all of
    them. A file changed again after it was staged is in both, each with its
    own diff. Above the lists is the commit message and the **Commit**
    button, which commits what is staged, with the identity and the hooks
    the repository is set up with. What git says when it refuses is shown.
    Not part of it: staging part of a file, discarding changes, amending,
    push and pull.
  - **History.** The conversations each agent had in the selected folder, one
    section per agent, newest first, with a title and how
    long ago it was. A conversation can be resumed, which opens it in its
    agent in a new session, or handed off to another agent. Like the Git
    tab it covers the selected folder only: conversations that ran in a
    subfolder belong to that subfolder. A switch at the top changes the list
    to **All**: every conversation on the Mac, each row naming its folder.

### Keeping the Mac awake

A switch in the Mac's Settings, and in the iPhone app's menu, keeps the Mac
from going to sleep by itself while a session is open, so agents keep
working and the phone can still reach them. The host holds the hold on
sleep, so it works with the window closed, and lets go when the last
session ends. The display may still turn off, and closing the lid still
puts the Mac to sleep. Off by default.

### Menu bar (Mac)

AgentTerm keeps an icon in the menu bar, and closing its window does not quit
it: the window and the Dock icon go, the menu bar icon stays. Its menu opens
the window again, lists the running sessions (picking one opens it), starts
an agent or a shell, opens pairing and Settings, and quits. Quit is there
and ⌘Q.

The setting "Keep AgentTerm in the menu bar when its window is closed", in
Settings (⌘,), is on by default. With it off there is no icon, and closing
the window quits the app. Sessions keep running either way, since the host
that holds them is a separate program.

### What agents may ask macOS for

macOS holds a terminal responsible for everything run inside it. An agent
that drives another app, takes a screenshot or reads a protected folder is
asking as AgentTerm, so AgentTerm has to be able to ask.

- **Asked by macOS when first used.** The app declares, with a sentence
  macOS shows the user, everything a program in a session may ask for:
  controlling other apps, camera, microphone, speech recognition, the Mac's
  audio, keyboard monitoring, Bluetooth, the local network, contacts,
  calendars, reminders, photos, the media library, location, and the Desktop,
  Documents, Downloads, removable, network and cloud storage folders. Without
  the declaration macOS refuses without asking. The released app carries the
  matching hardened runtime entitlements.
- **Never asked.** Settings (⌘,) > **Permissions** lists the ones agents
  rely on, says what each is for and whether it is allowed, and has a button
  that asks macOS for it or opens the right pane of System Settings:

| Permission | Used for |
|---|---|
| Accessibility | Clicking, typing and reading the screen in other apps: computer use in Claude Code and Codex, Antigravity's browser agent |
| Screen & System Audio Recording | Screenshots, which is how an agent sees an app or a page |
| Automation | Scripting another app, Chrome for one. Asked once per app |
| Full Disk Access | Folders macOS protects, such as Mail or other apps' data. Rarely needed |
| Microphone | Voice dictation in Claude Code and Antigravity |
| Camera | Only for a program that uses it |

Changes to Accessibility and Screen Recording apply to sessions started
after the app is reopened. A development build is a different app to macOS
and is asked separately.

### A host from another copy of the app

The host outlives the app, so a newly installed version can find the host of
an older one still running on its port, and would use it without a word. The
Mac app checks which program is the host. When it is not the one the app
ships with, a banner says so, with the other host's path, and offers **Use
This App's Host…**: the other host is stopped, after asking since its
sessions end with it, and the app's own is started.

### What the two apps share

The Mac and the iPhone offer the same things wherever the device allows:
folders (add, remove, reorder), the arrangement of sessions (order, pins
and groups, kept by the host so both show the same and a change on one
appears on the other), sessions (start, end), the terminal with a text size
setting, the Git view as a list or grouped by folder, History with both
scopes, resume, copying the resume command, and handoff from a past
conversation or a running session with the prompt shown.

They differ where the device does:

- The Mac refreshes Git and History by itself while it is in front. The
  iPhone loads them when a screen opens and on pull to refresh.
- The iPhone starts an agent in any folder through its folder picker. The Mac
  adds the folder to its list first.
- Pairing is one sided: the Mac shows codes and manages devices, the iPhone
  scans and manages Macs.
- "Show in Finder" is on the Mac only. The key bar and the compose field are
  on the iPhone only.
- On the Mac files and diffs open as tabs next to the terminals; on the
  iPhone they open as screens. The Mac's file tabs are arranged with the
  sessions' tabs but belong to its window; the iPhone leaves them alone.

### Files

A basic file manager and editor for the selected folder, enough to look at
and touch up what an agent wrote without leaving the app.

- The **Files** tab of the side panel is a tree of the folder's files and
  folders. Folders open in place. Files with uncommitted changes are marked
  the way the Git tab marks them.
- New file and new folder, in the folder itself or in any folder of the tree.
  Rename. Move to the Trash, after asking, so it can be put back. Show in
  Finder, copy the path. A name that is taken is refused; nothing is
  overwritten.
- Clicking a file opens it in the middle pane, as a tab next to the session
  tabs. Several files can be open. File tabs follow the session tabs, share
  their shortcuts (⌘1 to ⌘9, ⌘⇧], ⌘⇧[) and close with ⌘W. Starting or
  picking a session brings the terminal back to the front.
- Text opens in an editor with syntax coloring for the common languages. It
  saves with ⌘S, and a dot on the tab marks unsaved changes. Closing a tab
  with unsaved changes asks first.
- Markdown opens as a rendered preview, with a switch to the source. Code
  blocks in it are colored, and blocks marked `mermaid` are drawn as
  diagrams. A `.mmd` or `.mermaid` file is previewed as a diagram too.
- Images are shown. Files that are not text, or larger than 2 MB, are not
  opened.
- The tree, and open files without unsaved changes, follow changes made
  elsewhere, by an agent for one, within a few seconds.
- The files that were open come back as tabs the next time the app starts.

The iPhone has the same under a folder's **Files** tab, working on the
Mac's files through the host: the tree, new file and folder, rename, move
to the Mac's Trash and copy path (hold a row), and the same editor with
syntax coloring, Markdown and Mermaid preview and images. A file opens as
a screen; leaving it with unsaved changes asks first. It differs in three
ways: lines wrap, pictures a Markdown document refers to are not shown,
and what an agent changes shows after pulling down to refresh or reopening.

Not part of it: search, and a file changed on disk while it has unsaved
edits here is not merged; saving overwrites it.

### Pairing and remote access

- The Mac shows a QR code containing its Tailscale name, the port and a
  pairing code. The iPhone scans it and is paired. The same information can
  be copied from the Mac as a link and pasted into the iPhone app, or opened
  on the iPhone, for when scanning is not possible.
- A pairing code works once and for five minutes, and stops working when the
  pairing screen closes. The screen counts down, replaces a code that ran
  out, and can make a new one on demand. A code that leaked after it was used
  or after the screen closed is worth nothing.
- Pairing gives the iPhone a token of its own, kept in its Keychain. The Mac
  lists the paired devices, with when each last connected, and can remove
  one. A removed device is disconnected at once and has to pair again.
- All remote traffic goes through Tailscale. AgentTerm does not run a relay
  server and does not open a port on the local network.
- The pairing screen checks Tailscale on the Mac first. The code is shown only
  when Tailscale is installed, signed in and connected. Otherwise the screen
  shows what is missing (not installed, not signed in, or not connected) and
  the steps to fix it, with a button to get or open Tailscale, and switches to
  the code by itself once Tailscale is ready.
- Next to the code, the screen says that the iPhone needs Tailscale too, signed
  in to the same account.

### iPhone app

- The iPhone can be paired with several Macs. A menu lists them, switches
  between them and pairs another one. It shows one Mac at a time, and opens
  on the Mac it showed last. Forgetting a Mac leaves the others paired.
- List of sessions on the Mac on screen, with the folder each runs in.
- Full terminal for a session, sized to the screen.
- A key bar above the keyboard for keys a phone keyboard lacks: Esc, Tab,
  Shift+Tab, Ctrl, arrows, and Enter.
- A compose field for writing a prompt with the normal iOS keyboard,
  autocorrect and input methods, sent to the terminal in one go.
- Quick launch for the installed agents, in any folder known to the Mac.
- A folder picker browses the Mac's folders, starting at home, to start an
  agent or a shell in any of them. The folder can be added to the list the
  Mac and the iPhone share.
- Each folder opens what the Mac's side panel shows. **Git**: the changed
  files with added and removed line counts, and the diff of a file, which
  scrolls sideways; files can be staged, unstaged and committed as on the
  Mac. **History**: the conversations each agent had in the
  folder, with a switch to every conversation on the Mac. **Files**: see
  Files above.
- A conversation can be resumed in its agent, or handed off to another
  installed agent. The handoff sheet shows the prompt the agent will start
  with, which can be edited and reset, and takes optional instructions. Both
  open the new session's terminal on the iPhone.
- A running session can be handed off too, from its terminal's menu.
- A folder can be taken off the shared list.
- Text size can be changed, which changes how many columns fit.
- When the connection drops, the app reconnects on its own and returns to the
  session that was open.


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

- Running agents on the iPhone or on a server AgentTerm hosts.
- Remote access without Tailscale.
- A code editor. The changes pane is read-only.
- Windows and Linux hosts.

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| M1 Mac core | Host daemon, PTY sessions, protocol, macOS three-pane app, agent detection and quick launch, changes pane, pairing QR code | Done, except the Vietnamese input matrix, which is checked by hand and not yet run |
| M2 iPhone | iOS app: scan to pair, several Macs, session list, terminal sized to the phone, key bar, compose field, folder picker, changes, history, resume and handoff | Works in the iOS Simulator. Not yet run on a real iPhone, so QR scanning with the camera, Tailscale from the phone and typing with the Vietnamese keyboard are unverified |
| M3 Polish | Host as a login item, screen snapshot on attach, app icon, signed and notarized Mac build | Not started |
| M4 Awareness | Agent state (working, waiting, done) and notifications | Not started |
