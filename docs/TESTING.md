# Testing AgentTerm

What AgentTerm does, case by case, and what checks each case. The list
follows `SPEC.md`. Each case says three things:

- **Input**: what there is before anything is done: the data, and the state
  the apps and the host are in.
- **Action or event**: what the user does, or what happens.
- **Expected response**: what has to be true afterwards.

The last column says what checks the case. A case marked "hand" is checked
by nothing automatic, which is where a bug can sit unnoticed.

## The layers

| Mark | Layer | Run with | Runs in CI |
|---|---|---|---|
| H | Host and protocol: a real host over a loopback WebSocket | `swift test` | yes |
| P | iPhone app in the simulator, against two throwaway hosts | `scripts/test-ios.sh` | no |
| L | iPhone app on its side | `LANDSCAPE=only scripts/test-ios.sh` | no |
| M | Mac app, driven through accessibility, against a throwaway host | `scripts/test-mac.sh` | no |
| X | Mac app and iPhone app together on one host | `scripts/test-both.sh` | no |
| hand | Only by hand so far | | |

In M a second device, a phone say, is played by a client that speaks the
protocol: the Mac app is real, the other device is not. In X both apps are
real.

M and X need the terminal they run in to be allowed under System Settings >
Privacy & Security > Accessibility. They press and read the app's own
elements, as VoiceOver does: no pointer is moved and no key is sent. All
layers use state folders, ports, a home folder and preferences of their own,
and stand-in agents (small scripts) instead of the installed ones: the
installed app, its sessions, its paired devices and the user's accounts are
never touched.

## Running them

Everything is run from the root of the repository. Each script builds what
it needs first, prints one line per test, and on a failure says where the
full log is.

| To check | Run | Takes about |
|---|---|---|
| The host, the protocol and the shared code | `swift test` | 2 minutes |
| The Mac app | `scripts/test-mac.sh` | 5 minutes |
| The iPhone app | `scripts/test-ios.sh "iPhone Air"` | 10 minutes |
| The iPhone app on its side | `LANDSCAPE=only scripts/test-ios.sh "iPhone Air"` | a few minutes |
| Both apps on one host | `scripts/test-both.sh "iPhone Air"` | 5 minutes |

Before a release all of them are run, in that order: the first is the
quickest to say that something is broken, the last needs everything else
to work.

What they need, once:

- For M and X: the terminal they are run from, or the app a coding agent
  runs in, allowed under System Settings > Privacy & Security >
  Accessibility. Without it the Mac tests are skipped, not failed: a run
  that says "Executed 0 tests" or lists them as skipped checked nothing.
- For P, L and X: Xcode with an iPhone simulator, and `brew install
  xcodegen`. Name the simulator: the test resets its keychain, so it should
  not be the one an app you use is paired in. `scripts/test-ios.sh --list`
  shows the simulators.

One test, or a few:

```sh
swift test --filter OutputTrackerTests                    # a class
swift test --filter "ScreenMirrorTests|LoginItemTests"    # several
swift test --filter testAStringEndsWhereAnotherSequenceBegins
scripts/test-mac.sh RemoteMacTests                        # a class of the Mac app's
scripts/test-mac.sh "RemoteMacTests/testACommit"          # tests whose name starts so
scripts/test-mac.sh "RemoteMacTests/test(ACommit|AFile)"  # a pattern, as --filter takes
```

When a Mac test fails, its message ends with everything that was on screen
at that moment, element by element: most often that says what went wrong.
For a picture of the window as well:

```sh
SHOTS=/tmp/shots scripts/test-mac.sh RemoteMacTests               # of each test that fails
SHOTS=/tmp/shots ALL_SHOTS=1 scripts/test-mac.sh RemoteMacTests   # of every test, at its end
```

`ALL_SHOTS=1` is also the way to look at a change to the window without
opening the app: run a test that ends where the change shows, and look at
its picture. The iPhone scripts take `SHOTS` the same way.

### The figures

`scripts/measure.sh` (`CONFIGURATION=release` for the build users run)
takes the figures of `docs/PERFORMANCE.md` again: heavy cases made in a
folder of its own, each timed or weighed. Nothing fails on a figure;
compare with the table there after a change that may make AgentTerm
slower or larger.

### The pictures

The pictures of both apps, in the README, on the product page and in the
App Store, are taken the same way the apps are tested, by
`scripts/screenshots.sh`:

```sh
KEEP=/tmp/pictures scripts/screenshots.sh   # take them there, to look at first
scripts/screenshots.sh                      # put them where the pages take them from
ONLY=mac scripts/screenshots.sh             # only the Mac's three
ONLY=ios scripts/screenshots.sh             # only the iPhone's six
```

It builds the app into a folder of its own, starts a host with a demo
project, a second folder and stand-in agents (`scripts/demo-agent.py`,
which draws an agent's screen and reports usage without any account),
then runs `ScreenshotTests` of the Mac app and of the iPhone app. What a
picture shows is decided there: the demo project in the script, what the
agent says in `demo-agent.py`, where each picture is taken in the two
`ScreenshotTests`. They are taken again whenever a release changes what
they show, and looked at before they are committed. The iPhone's are
taken on the iPhone Air, whose screen is the size the App Store asks for.

### Where a new test goes

| What is tested | Where | Start from |
|---|---|---|
| What the host answers, what a client is sent | `Tests/AgentTermHostTests/EndToEndTests.swift` | a test there that connects a client |
| What a client is sent on attach | `Tests/AgentTermHostTests/ScreenMirrorTests.swift` | `session(_:)` and `attach(to:)`, which give the session's own terminal and a client's to compare |
| The connection itself | `Tests/AgentTermHostTests/SlowLinkTests.swift` | a host on a port of its own and a real `AgentTermConnection` |
| What one host leaves for the next: a host that died | `Tests/AgentTermHostTests/HostDeathTests.swift` | `startHost()`, which runs the real `agenttermd` on the test's own state folder and port, and `kill` |
| The host as launchd runs it | `Tests/AgentTermHostTests/LaunchdHostTests.swift` | a launch agent of the test's own: a label no app uses (`com.example.agentterm-test.…`), its property list in the test's folder, never `~/Library/LaunchAgents`, loaded into the user's launchd and unloaded after |
| The Mac app | a class under `Tests/AgentTermMacUITests` | `MacUITestCase`: `app.press`, `app.write`, `app.menu`, `app.wait(for:)`, and `device()` for a second device |
| The Mac app on another Mac | `RemoteMacTests` | `startOtherMac()` and `pair()` |
| The iPhone app | `iOS/AgentTermUITests` | the test `scripts/test-ios.sh` runs |

A Mac test finds an element by what VoiceOver would say of it:
`.button("Stage notes.txt")`, `.text("Commit message")`,
`.containing("the hook says no")`, `.id("mac-switcher")`. An element that
cannot be found that way has no name for VoiceOver either, which is worth
fixing in the app rather than working around in the test.

### A bug, before it is fixed

A bug that can be shown is shown first: a test that fails because of it,
run and seen to fail, then the fix, then the same test passing. The test
stays. What makes each kind of bug show:

- Something that depends on timing: make the slow thing slow. A git hook
  that sleeps (REMOTE-14), a link that carries little (`SlowProxy`,
  SES-9), output cut where the bug needs it cut (SES-16, SES-19).
- Something that fails on the other side: make it fail there. A folder
  nothing can be written in (REMOTE-15), a host that is stopped
  (REMOTE-18) or killed (`killHost(on:)`, HOST-5, REMOTE-19), a port held
  by something else (HOST-7), a device that is removed (REMOTE-8).
- Something one device does to another: a second client on the same host
  (`device()`), which also remembers everything the host told it
  (REMOTE-16).
- Something slow: time it in the test and compare with itself, not with
  a number of seconds that holds on one machine only (SES-21).

## Cases

"The fixture project" is a git repository with a remote, one commit, and
changes not yet committed: `notes.txt` with a second line, `docs/guide.md`
new, `new.txt` new. "A second device" is another client on the same host.

### Sessions

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| SES-1 | A host with no session | A client creates a session with the command `echo hello-$((40+2)); exit 3` | The output `hello-42` arrives, then the exit status 3, then a session list without it | H |
| SES-2 | The app connected, the fixture project selected | Press the Shell launch button | A session starts in the project's folder and its terminal is shown | P, M |
| SES-3 | Stand-in agents `claude` and `codex` installed | Press the Claude Code launch button | A session titled "Claude Code" starts, runs the agent's program, and has a tab | M |
| SES-4 | Two sessions running, one with a line typed and not sent | Quit the Mac app and open it again | Both sessions are listed again, under the same ids, with what was typed still at the prompt | M |
| SES-5 | A session open on the iPhone | The connection drops and comes back | The app reconnects by itself and is back in that session | H (the host side), hand (the app) |
| SES-6 | A session started on one device | A second device attaches to it | The second device gets the same output; a session started on the Mac is listed on the iPhone, and one started on the iPhone on the Mac | H, M, X |
| SES-7 | A session that wrote 20,000 lines | A client attaches | The screen and the 10,000 newest lines above it arrive whole, in pieces, with no line lost or torn, ending where the session is now | H |
| SES-8 | A client that was attached and got N bytes | It attaches again naming how far it is | Only what the session wrote since is sent; a place that is not this session's gets all of it again, and is told so | H |
| SES-9 | A link that carries 100 KB a second; a link that carries nothing | A replay of 300 KB is sent; nothing is sent | The slow connection stays open and gets all of it; the silent one is closed as lost | H |
| SES-10 | A session in front on the Mac; a session open on the iPhone | Choose End Session | The app asks first, nothing ends before the answer, and after it the session is gone from every device | P, M |
| SES-25 | A session on the Mac and on the iPhone | End it from the × of its row or its tab on the Mac, from its row's menu on the iPhone | Each asks first, as End Session does | P (the row's menu); hand for the Mac's ×, which shows under the pointer only, and the Mac's UI tests never move it |
| SES-11 | A client that is not attached to a session | It sends input for that session | The input does not reach the program | H |
| SES-12 | Text written for a session and not sent | Leave the terminal, or close the app, and come back | iPhone: the text is in the message field again. Mac: it is still at the program's prompt | P; M as far as the host goes: the session is there and replays what was typed. What the Mac's terminal draws cannot be read through accessibility |
| SES-13 | A replay holding a question the program once asked its terminal | The replay is fed slowly, longer than five seconds in all | The emulator's answer does not reach the program; a question asked after the replay is answered | H |
| SES-14 | A full screen program on the other screen, with the cursor hidden, the mouse and pastes reported | A client attaches | Its emulator shows the same screen, cursor and modes without the program drawing again; when the program ends both are back at the shell's screen | H |
| SES-15 | Output drawn for 80 columns, then a session resized to 40 | A client attaches | The lines are laid out for 40 columns, as in the session's own terminal | H |
| SES-16 | Output that stops in the middle of a color sequence, a character of three bytes, or a title | A client attaches at that moment, and the rest is written | The client shows what the session's own terminal shows: nothing of the sequence appears as text | H |
| SES-17 | A program that asked where the cursor is and which terminal this is | A client attaches | Nothing in what it is sent makes its emulator answer | H |
| SES-18 | An emulator that already holds other text and is on the other screen | It is sent a session's screen | It is left as the session is, with nothing of before | H |
| SES-19 | A title that never ends: its program was killed, or the output is binary; then colored text | A client attaches, also right after the escape that cut the title short | The client shows what the session's own terminal shows, once, in its colors | H |
| SES-20 | An image of 1.5 MB being written, more than is kept of one sequence | A client attaches in the middle of it, and the rest is written | The client is sent a few kilobytes, misses the image and draws none of it as text; what follows the image shows | H |
| SES-21 | A session with 10,000 lines that says nothing meanwhile | Ten clients attach one after the other | The screen is written out once: the ten take less time together than the first did. After more output it is written out anew. Writing out 10,040 lines takes less than eight times as long as writing out 2,640: in proportion to the lines, not more | H |
| SES-22 | A client that is still connecting | It is asked to send something | That waits and follows the greeting; the host answers it instead of closing a client whose first word was not its hello | H |
| SES-23 | A session whose program waits | Its program is killed (SIGKILL) | Every client is told that the program of that session stopped unexpectedly, that it was killed, and that its session ended; it is not started again | H |
| SES-24 | A session whose program ignores the hang-up; another that waits | The first is closed from a device (SIGHUP, then SIGKILL); the second is stopped by Control C (SIGINT) | Nothing is reported | H |

### Session names and usage

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| NAME-1 | An agent's session whose agent saved a conversation | The host looks at the sessions | The session is named after the conversation's title | H |
| NAME-2 | Two sessions of one agent in one folder | Each has its own conversation | Each session gets its own conversation, not the other's | H |
| NAME-3 | A session started on the Mac | Look at the folder list, the tabs, and the iPhone | The same name and icon in all three | M (Mac), X (name on the iPhone) |
| USE-1 | What each agent's service answers about limits | The host reads it | The limits are listed as the agent's own usage screen lists them | H |
| USE-2 | A sign-in for one service; one that has run out | The host asks for usage | The sign-in goes only to the service that issued it; one that ran out is not sent and never renewed | H |
| USE-3 | An agent's session in front | Look under the terminal, press the band | The band shows model, context and limits; pressing it opens the details | hand (the band is there in M; its figures need a real account) |
| USE-4 | A user with a status line of their own | Claude Code runs AgentTerm's status line | The user's own still runs, with the same input | H |
| USE-5 | A Claude Code session whose usage the status line relay cannot save | The relay runs; it saves again; then it cannot again | The relay leaves why next to the file and removes it once it saves. The host reports it once for the session, with the relay's words, and again after it was saved in between | H |

### The Mac at a glance

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| SYS-1 | A host with a client connected | Three seconds pass | The six figures are measured and sent | H |
| SYS-2 | The app connected | Look under the launch buttons in Sessions (Mac), above the sessions (iPhone) | Processor, memory, network down and up, temperature, battery, uptime are shown | P, M |
| SYS-3 | Temperature in Celsius | A second device chooses Fahrenheit | The Mac's line shows °F | H, M |

### Terminal size

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| SIZE-1 | Two clients attached with different sizes | One takes control; the other only watches | The PTY has the size of the one that took control; watching changes nothing | H |
| SIZE-2 | A client attached that is not the driver | Its emulator answers a question by itself | The session is not taken away from the driver | H |
| SIZE-3 | A session open on the iPhone | The Mac takes the session at a larger size | The iPhone shows the Mac's terminal scaled down with "Fit This Screen", which takes it back | P (`TAKEOVER=1`) |
| SIZE-4 | A session started on the Mac | A second device takes control at 40 × 20 | The Mac says another device is using it, names 40 × 20, and offers "Use This Window's Size"; pressing it gives the Mac's size back | M |
| SIZE-5 | A session at the size that fits | Make the text four steps larger, then back to the actual size | Fewer columns while it is larger; the same number again afterwards | P, M |
| SIZE-6 | A session open on the iPhone | Turn the phone on its side, bring up the keyboard | The terminal keeps a usable height; one row holds back, the keys, the message field and the menu | L |
| SIZE-7 | The Mac's launch screen, its line of figures shown | Start a shell | It starts at the size its pane shows it at, not one it is made smaller to afterwards | M |
| SIZE-8 | A session the Mac and the iPhone show, the iPhone using it | The iPhone goes; the Mac's window is resized; the Mac app is used; the Mac types in it | The session stays at the iPhone's size and nobody drives until the Mac types, then it takes the Mac's; an iPhone coming back takes its own at once, without a button | H |

### Quick launch and SSH

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| LAUNCH-1 | Two of the four agents installed | Open the app | Launch buttons for those two and for Shell, none for the other two | H, M |
| LAUNCH-2 | `~/.ssh/config` with `Host build-server`, `Host *.internal` | Open the SSH menu | `build-server` is listed; the pattern is not | H, P, M |
| LAUNCH-3 | The same configuration | A client asks to open a host the configuration does not name | The host refuses | H |
| LAUNCH-4 | No SSH configuration | Open the app | There is no SSH menu | M |
| LAUNCH-5 | A `Host` line with a comment after it | The host reads the configuration | The words of the comment are not hosts | H |

### Handoff

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| HAND-1 | A conversation of each agent, with tool traffic in it | Prepare a handoff | The file holds what the user and the agent said, without the tool traffic | H |
| HAND-2 | A git repository | Prepare a handoff | The file is in `.agentterm/handoffs/`, and git does not list it as a change | H, M |
| HAND-3 | A past conversation of Claude Code, Codex installed too | Choose Hand Off on the conversation | A sheet names Codex and shows the prompt it will start with, naming the handoff file | P, M |
| HAND-4 | The sheet from HAND-3 | Press Hand Off | A Codex session starts, told to read the handoff file, and the file exists in the project | P, M |
| HAND-5 | The same, with another folder picked under Continue in | Press Hand Off | The agent starts in that folder, which is added to the list | M |
| HAND-6 | A running session of an agent | Choose Hand Off from the session's menu | The sheet opens for that session's conversation | P, M |

### The Mac window and its tabs

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| WIN-1 | A host with one folder | A second device adds a folder, then removes it | The Mac's list gains the folder, then loses it | H, P, M |
| WIN-2 | A session started in a folder that is not listed | Look at the list | The session is under "Other" | P, M |
| WIN-3 | The window with all three panes | Press Sessions in the bar of places twice, the Side Panel button twice | Each pane goes and comes back | M |
| WIN-4 | The window on Sessions, with a session, conversations in two folders | Press History, then Settings, then Sessions | History lists every conversation at the left; the side panel is in Sessions only; Settings lists its panes at the left and shows General in the middle, the terminal hidden; the line of figures is in neither; back on Sessions the folders, the line of figures and the session's terminal are there again | M |
| WIN-5 | The window on Settings, History or Schedules | Start a shell or an agent from the header | It is shown in Sessions | M |
| TAB-1 | Three sessions | Pick one in the sidebar | It has a tab and its terminal is shown | M |
| TAB-2 | The same | Pin the tab in front; add another to a new group | The host has the pin and the group | H, P, M |
| TAB-3 | The arrangement from TAB-2 | Quit the Mac app and open it again; look on a second device | The same arrangement on both, also after the restart | H, P, M |
| TAB-4 | Several tabs, one pinned, one file with unsaved changes | Close Others, Close All | The app asks before ending sessions; the pinned tab and the unsaved file stay | M (Close Others: it asks, and the pinned tab stays) |
| TAB-5 | A file open and a diff picked | Look at the strip of tabs | The file and the diff are tabs next to the sessions | M (as part of FILE-3 and GIT-4) |

### Git

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| GIT-1 | The fixture project | Open the Git tab | `notes.txt`, `guide.md` and `new.txt` are listed under Changes, each with a button to stage it | H, P, M |
| GIT-2 | The same | Stage `notes.txt`; Stage all; unstage `new.txt` | After each step git's index holds exactly what the lists show as staged | H, P, M |
| GIT-3a | Two files staged, a message in the field | Press Commit | git has a commit with that message; the committed files leave the list, the others stay, the field is empty | H, P, M |
| GIT-3b | A pre-commit hook that prints a message and fails | Press Commit | git's own words are shown; no commit is made; the message stays in the field | H, M |
| GIT-3c | A pre-commit hook that records the environment it is given | Press Commit | The hook sees `GIT_TERMINAL_PROMPT=0`, no `GIT_ASKPASS` and `SSH_ASKPASS_REQUIRE=never`, as push and pull do; the commit has the message as written | H |
| GIT-4 | `notes.txt` changed | Pick it in the list; switch to two panels and back | Its diff opens as a tab with `+second line`; in two panels the line is on the right without its mark | P, M |
| GIT-5 | Changes in several folders | Press Group by folder | The list becomes a tree; folders fold and show totals | H, P, X |
| GIT-6 | One panel and a flat list on both devices | Choose two panels, or the tree, on one device | The other device shows the same choice | H, M, X |
| GIT-7 | One commit that the remote does not have | Press Push | The remote has the commit | H, P, M |
| GIT-8 | A pull that would conflict; a remote that asks for a password | Pull; push | The pull is undone and says so; git fails with its own message instead of waiting | H |
| GIT-9 | A push under way on the iPhone | The changes are asked for again meanwhile | That answer is not taken for the end of the push | H |
| GIT-10 | Files staged, a stand-in agent that answers with a message | Press Write | The agent's message is in the field; nothing is committed | H, M |
| GIT-11 | Default commit message settings | A second device sets agent Codex, a model and a prompt | Settings > Git shows that agent, model and prompt, and the Write button names Codex | H, M |
| GIT-12 | Changes listed on the Mac | Another device stages everything and commits | The Mac's list is empty and git has that device's commit | M, X |
| GIT-13 | A diff scrolled part of the way down | The file changes under it | The diff stays where it was scrolled to | M |
| GIT-14 | A remote that wants a sign-in; a credential helper (`!name`) in a folder only the login shell's `PATH` names | Push; pull | git finds and runs the helper | H |
| GIT-15 | A pre-commit hook that calls a tool in a folder only the login shell's `PATH` names | Press Commit | The hook finds the tool; the commit is made | H |
| GIT-16 | A credential helper that is nowhere, written as `!name args` or as a name git knows (`credential.helper = name`) | Push | The first line says "git could not sign in to <host>: its credential helper `name` was not found."; git's own words follow. A helper that answers with a sign-in the remote refuses is not called missing | H |
| GIT-17 | The login shell asked once, before a tool the hook calls was installed | The shell's `PATH` now names the tool's folder; press Commit | The shell is asked again and the commit made on the second try; when the shell's `PATH` is the same, the action is not tried again | H |
| GIT-18 | A login shell that prints its `PATH` after other lines, or prints nothing | The host asks it | Only the `PATH` behind the marker is taken, once; with nothing, git keeps the host's `PATH` and `GIT_TERMINAL_PROMPT=0` is still set | H |
| GIT-19 | The host tests, which stand in no shell of their own | A git action asks for the login shell's `PATH` | The user's own shell is not started and none of their startup files is read; the `PATH` stays the host's | H |

### History

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| HIST-1 | Conversations of each agent in a folder, a subfolder and a look-alike sibling | The host lists the folder's conversations | Only that folder's, newest first | H |
| HIST-2 | One conversation of Claude Code in the fixture project | Open History | The conversation is listed, with "1 conversation"; on the Mac every conversation is, with no switch to one folder's | P, M |
| HIST-3 | The same | Choose Resume | A new session of that agent starts with the conversation's id on its command line | H, P, M |
| HIST-4 | History on the Mac, one conversation | Look in the middle; pick the conversation | "Choose a conversation", not a folder's launch screen; then the conversation: its agent, title and folder, Resume, Copy Resume Command, and the handoff form with the agents to hand it to | M |
| HIST-5 | The Mac's Sessions, a conversation in the folder and one in another folder | Open the side panel's History; pick the conversation | Only the folder's is listed; picked, it is shown in a sheet over Sessions, which stays, with Resume and the handoff; Close puts it away | M |
| HIST-6 | A session of 3,000 lines opened again on the iPhone | Scroll to the top, twice | It came with 500 lines above the screen; each time earlier lines load, 1,000 more, a strip saying so, and the line in view stays in view; the host writes out only as many as asked and says how many it keeps | H, P |
| PERF-6 | A terminal of 5,000 lines on the iPhone | A fast swipe, five times (`SCROLL=only scripts/test-ios.sh`) | The app's processor work while it coasts is measured; the figures are in PERFORMANCE.md | P |
| PERF-7 | A session of 10,000 lines | A client attaches; another asks something meanwhile; the session writes meanwhile | The other is answered at once (measured: `scripts/measure.sh`); what was written follows the screen | H |
| PERF-8 | The real host, on a state folder of its own | Twenty sessions opened and ended, then 180 more (`scripts/measure.sh`) | `leaks` finds nothing; what it has allocated (`heap`) after 200 is within 15% of what it was after the first 20 | H |

### Keeping the Mac awake, starting at login

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| AWAKE-1 | Keep awake on | A session starts; the last session ends | The hold on sleep is taken, then let go | H |
| AWAKE-2 | Keep awake off on both devices | Switch it on on the Mac; switch it off, or an option on, on a second device | Each device shows what the other set | H, P, M, X |
| AWAKE-3 | Keep awake on with "after 1 hour" | The hour passes | The switch goes off on both devices | H |
| AWAKE-4 | Keep awake on, a session running, macOS refusing the hold | Refreshes go by; then macOS gives the hold | It is reported once, that the Mac could not be kept awake; once held, the report says it is kept awake again | H |
| AWAKE-5 | Keep awake on with "only while an agent is working", a shell and an agent | The agent works, waits for permission, works, is done; then the option is turned off | Held while it works, let go while it waits and when it is done; the shell holds nothing. Off, the sessions hold the Mac awake as before. Options saved before the option existed read with it off | H |
| LOGIN-1 | A host that can be started at login | A client switches Start at Login on, then off | A launch agent naming this host's program is written, then removed; every client is told | H |
| LOGIN-2 | A host with a state folder of its own | Connect | No client shows the switch | H |
| LOGIN-3 | Start at Login on | Log out and in again | The host is running without the app having been opened | hand |
| LOGIN-4 | Start at Login on, and the app moved since: the launch agent names its host where it was | The app's host starts from where the app is now | The launch agent names this host's program | H |
| LOGIN-5 | Start at Login on for the installed app | A build that is not part of an app starts its host, or the installed host is started by hand with other arguments | The launch agent is left as it was | H |
| LOGIN-6 | A host launchd started from its launch agent, the app closed | The host is killed (SIGKILL); then it is stopped as asked (SIGTERM) | launchd starts it again after the kill, and says it was killed; after the stop it does not | H |
| LOGIN-7 | Start at Login on | The app starts its host; again while it runs; the host is killed within ten seconds of its start and the app starts it; Start at Login is turned off, the host stopped, and the app starts it | launchd starts it, once; started again at once, not after launchd's ten seconds, and the app is told it was killed; with the switch off the app starts its own and launchd has no job left | H |
| LOGIN-8 | A launch agent written by 0.5.0, without `KeepAlive` | The host it names starts; the same host started by hand with other arguments | It is written again as this version writes it; by the other, it is left as it was | H |

### Menu bar, permissions, the host

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| MENU-1 | The window open | Close it | The menu bar icon stays, and its menu opens the window again | hand |
| MENU-2 | The app running | Choose File > New Shell, New Claude Code | A session of each kind starts | M |
| PERM-1 | The app running | Open Settings > Permissions | Each permission is listed with whether it is allowed | M |
| HOST-1 | A host from another copy of the app on the app's port | Open the app | A banner names the other host's path and offers this app's own | M |
| HOST-2 | A host of another protocol version | Connect | Both apps say the versions differ | H, P |
| HOST-3 | A host with two sessions, `build` and `tests` | The host is killed (SIGKILL), and another is started on its state folder and port | Every client is told that the host stopped, about when, that `build` and `tests` ended with it, and that it was started again; so is a client that connects later, also after the host is restarted on purpose. Dismissed on one client, it is gone from all and not sent again | H |
| HOST-4 | A host with two sessions | It is stopped as asked for (SIGTERM: Restart Host, replacing another copy's host, logging out), and started again | Nothing is reported | H |
| HOST-5 | The Mac app on its host, a session `build` running | The host is killed | The app starts its host again by itself and shows a banner: the host stopped unexpectedly, was started again, and `build` ended with it. Dismiss takes it away here and on the host | M |
| HOST-6 | The Mac app on its host | The host is killed three times within sixty seconds | After the third the app does not start it again: it says the host keeps stopping, how often, why the last one stopped (it was killed), and offers Try Again, which starts it; the new host then reports the three | M |
| HOST-7 | The app's port held by something that is not a host | Open the app | The host it starts cannot listen there; the app says it could not be started, with the host's own words why, and offers Try Again | M |
| HOST-9 | A host started again each time it died, by launchd with the app closed | It dies three times within sixty seconds; then the user asks for it (Try Again) | The host after the third does not run: it exits with status 0, so launchd leaves it, and the third report says it keeps stopping. After Try Again it runs, and one more death does not break it | H |
| HOST-8 | The host on the Mac died with two sessions before this one started | The iPhone connects | A card says "The host on <Mac> stopped unexpectedly … and was started again", names the two sessions that ended, and goes once dismissed | P |

### Files

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| FILE-1 | The fixture project | Open the Files tab; press the `docs` folder | Folders come first, `.git` is not listed, and `docs` opens in place showing `guide.md` | H, P, M |
| FILE-2 | The same | New file, new folder, rename, move to the Trash; a name that is taken | Each is done on disk; the taken name is refused and nothing is overwritten | H, P, M |
| FILE-3 | `notes.txt` with two lines | Open it, add a third line, choose Save | The editor shows the two lines; the disk is unchanged until Save, and has three lines after | H, P, M |
| FILE-4 | A Markdown file with a Mermaid block | Open it | A rendered preview with a switch to the source | H (Markdown), M |
| FILE-5 | An image, a binary file, a file over 2 MB | Open each | The image shows; the others say why they do not | H, M |
| FILE-6 | A file open without edits | Something else rewrites it on disk; press Refresh | The editor shows the new text | M |
| FILE-7 | A file open as a tab | Quit the app and open it again | The file is a tab again | M |
| FILE-8 | The Files tab open on the Mac | A second device creates a file and writes into it | The file appears in the Mac's tree and opens with that text | M |
| FILE-9 | A text file of 3 MB, and one over 20 MB | Open it | It says it is too large to open by itself and offers Open Anyway, which opens it; over 20 MB it is not offered | H, M |

### Pairing and devices

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| PAIR-1 | A pairing code on show | It is used once; used again; five minutes pass; the window closes | It pairs one device; every later use is refused | H |
| PAIR-2 | A pairing link | Open it on the iPhone | The iPhone is paired with a token of its own and shows the Mac | H, P, X |
| PAIR-3 | A paired device's client | It asks for a pairing code, or to remove a device | The host refuses: only the Mac's own client may | H |
| PAIR-4 | Tailscale connected, or not | Open the pairing window | A code, or what Tailscale is missing with the steps to fix it | M (one or the other, whichever this Mac is in) |
| PAIR-5 | A paired device connected | The Mac removes it | It is disconnected at once and has to pair again | H, M (a paired Mac) |
| PAIR-6 | The iPhone paired with one Mac | Pair a second; switch between them | Both are listed; each shows its own folders and sessions | P |

### Another Mac

A second host stands in for the other Mac, with a project of its own.

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| REMOTE-1 | The other Mac's pairing link | Choose Pair with Another Mac, paste the link | The other Mac is on screen and named in the menu | M |
| REMOTE-2 | Paired | Look at the folders | The other Mac's folder is listed and this Mac's is not | M |
| REMOTE-3 | A changed file on the other Mac | Stage it, commit with a message; open a file, change it, save | The other Mac's git has the commit and its disk has the saved text | M |
| REMOTE-4 | The other Mac's home with `Sites/blog` | Press Add; go into Sites, into blog; press Add This Folder | The other Mac's list has the folder and it shows here | M |
| REMOTE-5 | A session started on the other Mac from here | Switch to This Mac, then back | This Mac shows its own folder; back on the other Mac the session is still running | M |
| REMOTE-6 | The other Mac on screen | Quit the app and open it again | It comes back to the other Mac | M |
| REMOTE-7 | The other Mac on screen | Look for Pair Device | It is not offered | M (Pair Device), hand (Show in Finder, Restart Host) |
| REMOTE-8 | Paired | The other Mac removes this one from its devices | A message says so, the other Mac is forgotten, and this Mac is on screen | M |
| REMOTE-9 | A file of the other Mac open with unsaved changes | Switch to This Mac | Refused, with a message to save or discard first; the other Mac stays on screen | M |
| REMOTE-10 | A changed file on the other Mac | Pick it in the Git tab | Its diff, which comes after the list, is shown | M |
| REMOTE-11 | A file staged on the other Mac, a stand-in agent there | Press Write, then Commit | The other Mac's agent writes the message into the field, and its git has the commit | M |
| REMOTE-12 | That commit, which the other Mac's remote does not have | Press Push | The other Mac's remote has the commit | M |
| REMOTE-13 | A conversation an agent had on the other Mac | Choose Hand Off on it, press Hand Off | The prompt comes from the other Mac's host; the receiving agent starts there and the handoff file is on its disk | M |
| REMOTE-20 | Another Mac on screen | Choose Hand Off on a conversation, or make a schedule, and press Choose… | The other Mac's folders are browsed through its host and the one chosen is used; the repositories inside the conversation's folder are offered | M |
| REMOTE-14 | A file staged on the other Mac, whose git has a hook that takes six seconds and then refuses | Write a message, press Commit | What the hook said is shown, and the message is still in the field | M |
| REMOTE-15 | A file of the other Mac open, in a folder nothing can be written in | Change it, save, press Refresh in the Files tab | It is said that the file could not be saved; the changes are still in the editor, still count as not saved, and the other Mac's disk is as it was | M |
| REMOTE-16 | A session on this Mac, so its host has a tab to arrange | Pair with the other Mac, start a session there, come back | The other Mac's host was never told of this Mac's tab, and this Mac's arrangement is as it was | M |
| REMOTE-17 | A file of the other Mac open with unsaved changes | Choose Forget for the Mac on screen, confirm | Refused, with a message to save or discard first; the other Mac stays on screen and in the menu | M |
| REMOTE-18 | The app last on the other Mac, and this Mac's host not running, as after a restart | Open the app | It comes back to the other Mac, and this Mac's host is started all the same | M |
| REMOTE-19 | The other Mac on screen, a session `deploy` running there | The other Mac's host is killed and started again there | A banner says that the host on the other Mac stopped unexpectedly and was started again, and that `deploy` ended with it, rather than an empty list | M |

### iPhone only

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| IOS-1 | A shell with a command in its history | Press Up, then Return, in the key bar | The command runs again | P |
| IOS-2 | A shell open | Write `echo Xin chào tiếng Việt: ờ ữ ẩ đ` in the message field, press Send | The terminal shows the text as written | P, H |
| IOS-3 | Text in the message field, the keyboard up | Press the hide keyboard button | The keyboard goes; the text stays | P, L |
| IOS-4 | A session open, the phone on its side | Bring up the keyboard | There is still terminal to see, and a way back without the navigation bar | L |
| IOS-5 | The Mac's home with folders | Open Another Folder, pick one, start a shell | The shell starts in that folder | H, P |
| IOS-6 | The History or Settings tab in front | The Mac answers with an error | The message shows over whichever tab is in front | P |
| IOS-7 | Paired | Look at the three tabs | Sessions, History, Settings, with the settings the Mac's Settings has | P |

### Waiting

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| LOAD-1 | A slow link to the Mac | Open the History tab; open a session with megabytes behind it | A spinner with what is loading: "Loading the history…", "Loading the session…" | M (the session); the iPhone by hand |
| LOAD-2 | The same, slower still | Ten seconds pass | It says that it is taking longer than usual, and offers Try Again where that can be done | M; the iPhone by hand |

### What the agent is doing

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| AGENT-1 | What Claude Code tells its hooks, as recorded | A prompt; a question (`AskUserQuestion`); a command that runs; one that asks permission; the end of the turn | Working; waiting for an answer, with the question and its choices; working; waiting for permission, with the command; done, with the end of what it said | H |
| AGENT-2 | What Copilot CLI tells its hooks, as recorded | The same | The same, done without what it said; a question's choices from its form | H |
| AGENT-3 | What Antigravity tells its hooks, as recorded | A model call; a question; a command; the end with nothing running | Working; waiting for an answer; not known while the command runs; done. Its `PreToolUse` hook answers "allow" | H |
| AGENT-4 | What Codex's documentation says its hooks are told | A prompt; a permission; the end; an interrupt | Working; waiting for permission, in its own words; done; not known | H |
| AGENT-5 | Each agent | Its session starts | It is given hooks for that session only, whose command is the same for every session; Antigravity's trusted folders are the user's and the host's, and the user's settings are not changed | H |
| AGENT-6 | A stand-in agent telling its hooks through `agenttermd hook`, two devices, and a shell | It works, asks permission, works, ends | Each state is told when it begins, once, to both devices; a device that connects later is told the state as it is; the shell has none | H |
| AGENT-7 | A working agent | Escape alone, or Control C, is typed | Its state is not known until it says more. An arrow key changes nothing | H |
| AGENT-8 | A session of Codex and one of Antigravity | They start | Codex's says how to trust the hooks; Antigravity's says it cannot tell when it waits for permission | H |
| AGENT-9 | A stand-in agent that waits for permission | The Mac app shows it | A mark next to its name in the folder list and on its tab, read as "waiting for permission"; its folder's row says a session waits | M |
| AGENT-10 | The same | The iPhone shows it | A mark in the sessions list, and the state in the terminal's title | hand, until the iPhone tests cover it |

### Worktrees

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| WT-1 | A project with a change not committed and an ignored `.env` | A worktree is made for Claude Code; another; one with a name taken | `agentterm/claude-1` in `.agentterm/worktrees`, at the project's commit, without the change or `.env`, not seen by git as a change; then `agentterm/claude-2`; the taken name refused | H |
| WT-2 | Two worktrees | Each changes the same file; the first is merged before and after committing; the second thrown away without its branch | Neither sees the other's change; listed with what is changed and ahead; not merged with changes not committed; merged, removed with its branch; the second removed, its branch kept | H |
| WT-3 | A worktree made by hand outside the project, one whose folder is gone | Listed, a session in a folder inside the first | The project's first; the others with their paths, the first in use, the second missing; nothing removed | H |
| WT-4 | A folder with a setup command | A session is started in a new worktree | It runs in the worktree, with its branch and its agent known; the setup ran there first; the worktree is listed in use | H |
| WT-5 | A worktree a session runs in | It is thrown away; the session ends; it is thrown away | Refused; then removed | H |
| WT-6 | `.agentterm/` in a project | The Files tab lists the project | It is not listed | H |
| WT-7 | The Mac app, a session in a new worktree with a change of its own | The session is selected | Listed under its project with its branch; the side panel's bar names the branch and the Git tab shows the worktree's change, not the project's | M |
| WT-8 | The Mac app | Merge, open a pull request, throw away from the bar; a folder with uncommitted changes started in a new worktree | Each as WT-2 says; the question before starting | hand, until the UI tests cover it |

### Schedules

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| SCHED-1 | Each kind of time | The next time after a moment | Today's or tomorrow's for every day, the nearest weekday's, the moment for once until it passed, none for a limit reset | H |
| SCHED-2 | Each agent and mode | A run's command line | The agent's own switch for the mode and the prompt quoted; Copilot CLI's variable; Codex offers no "accept edits"; the warning names what Codex's runs do with hooks | H |
| SCHED-3 | Claude Code's and Copilot CLI's settings with other things in them | A schedule is saved | Its folder is trusted in them; the rest is as it was | H |
| SCHED-4 | A schedule that skips permissions | Saved without its warning accepted; with it; Codex with "accept edits" | Refused; saved, every client told with when it runs next; refused | H |
| SCHED-5 | Every day at nine, the clock at 8:59 | Nine comes | One session of its agent in its folder, named after it, marked as its run, started with the mode's switch and the prompt; recorded as started; once | H |
| SCHED-6 | The first run still going | The next day's time comes | Skipped, and said to be | H |
| SCHED-7 | Three schedules: one that catches up, one that does not, one off | Three days pass at once | The first runs once, said to be missed; the second is recorded as missed; the third does not run | H |
| SCHED-8 | A schedule a minute away; then hours away | It is saved | The Mac is held awake; then let go | H |
| SCHED-9 | Copilot CLI skipping all | It runs | Started with `COPILOT_ALLOW_ALL=true` | H |
| SCHED-10 | Every day at nine, made at 9:31 | A moment passes | Nothing runs until tomorrow | H |
| SCHED-11 | The Mac app and the iPhone | A schedule is made with "skip all permissions" | The warning is shown, and only once it is accepted is the schedule saved; both show it | hand, until the UI tests cover it |
| SCHED-12 | A schedule for when the limit resets | The account's limit starts over | It runs two minutes later | hand: needs an account whose limit resets |
| SCHED-13 | The Mac's Schedules with a schedule half made | Sessions is picked, then Schedules again | The schedule is dropped; the middle asks for one | M |
| SCHED-14 | A daily schedule and a schedule a moment away | Its time comes; its run is picked; the run's session ends; the daily one is picked | Both under Scheduled, none running; then the run under Running, opening its session; then under Past Runs as started; the daily one in the middle to change, with no runs. The iPhone shows the same three groups | H, M, P |

### When an agent is done or needs you

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| NOTE-1 | Sessions whose agents wait, work, are done | Their states change | Told once when done or waiting, again when asked something else, not while it keeps waiting; what waits is told on connecting; an ended session is forgotten | P |
| NOTE-2 | An agent waiting for permission | A reply to what it asked before; then one to what it asks now | The first is dropped and the device is told the agent moved on; the second is typed, then Return | H |
| NOTE-3 | The Mac left alone for six minutes | Its app comes to the front and goes behind; a key is pressed | Every client is told in use, not in use, in use | H |
| NOTE-7 | The Mac app in front, someone at the keyboard | The iPhone takes a session; it goes; the Mac app is used | No one is at the Mac from the iPhone's use, also once it is gone, until the Mac app is used | H |
| NOTE-4 | The Mac app with a shell in front and History shown, an agent in another session | The agent comes to wait for permission | A banner names the session and what it asks; Open selects it | M |
| NOTE-5 | The iPhone in the sessions list, an agent in a session | The agent finishes | A banner over the list, which opens the session | hand, until the iPhone tests cover it |
| NOTE-6 | The iPhone just left, an agent asks a question | The notification is answered with a reply | The reply is typed into the session after unlocking | hand: needs a real phone |

### The Live Activity

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| LIVE-1 | Agents working, waiting, done; the Mac in use or not; connected or not; the switch | What the Live Activity does | Shown only while connected, no one at the Mac and an agent works or waits; ended at once otherwise; left showing "done" when all are done | P |
| LIVE-2 | The iPhone connected, the Mac left alone, an agent working | The lock screen and the Dynamic Island | They show how many work and which wait; touching it opens the session that waits | hand: needs a real phone, as does how long iOS keeps it up to date |

### Shells an agent opens

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| MCP-1 | The MCP server outside a session of AgentTerm | It is started, asked for its tools | It answers MCP's handshake and offers no tools | H |
| MCP-2 | The MCP server in a session, a host standing in | Each tool is called | Each asks the host what it does and says what came of it; a refusal is an error | H |
| MCP-3 | A screen that changes, then stays | `wait` for a text; `wait` for stillness; `wait` for a text that never comes | Returns when the text is there, when the screen is still, or when the time is up, with the screen | H |
| MCP-4 | Two agents installed, one not | AgentTerm runs for the first time; again; after its program moved; turned off; on | Each installed agent is asked once with its own `mcp add` for the whole user; nothing the second time; replaced after a move; removed with `mcp remove` when off, and only from those it was installed in | H |
| MCP-5 | A stand-in agent that starts the real `agenttermd mcp` | It opens a shell running `cat`, types into it, waits, reads it | A session in its folder, marked as opened by it, that a second device lists; what it types reaches the program and is on the screen it reads | H |
| MCP-6 | Two agents, one with a shell it opened, and the user's own session | Each reads and types into the user's session and the other agent's session; the second lists the shells, types into the first's and waits for it | The sessions are refused; the second lists the first's shell with its folder, and what it types is on its screen | H |
| MCP-7 | An agent | It opens a shell running `claude` | Refused | H |
| MCP-8 | An agent with a shell it opened | The agent's session ends; a third agent lists the shells; the second closes the shell | The shell stays and the third lists it; closed, it ends and none is listed | H |
| MCP-9 | The Mac app and the iPhone | Settings | A switch, "Agents can open shells you see", that turns the server off and on for every device | hand, until the UI tests cover it |
| MCP-10 | A stand-in Claude Code | Started with the setting on, as by default; then off | On: its session's variable says `use` and it is asked in its system prompt; the server's instructions say to run commands in its shells. Off: neither | H |
| MCP-11 | Codex, which gives an MCP server only the variables its configuration names | The server is installed; installed by a host from before; the user named variables of their own | Its table in Codex's configuration names the session's variable, once, next to the user's | H |
| MCP-12 | A shell an agent opened | The Mac shows it | The Mac is the one using it, at its size: the agent's server only asks and is not attached, so nothing says another device uses it | H |
| MCP-13 | Copilot CLI and Antigravity, "Agents run their commands in shells you see" on, then off | Each is started | Antigravity gets a rule always on in its folder, Copilot CLI a folder of instructions after the user's own; off, neither | H |

### Vietnamese input

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| VN-1 | Vietnamese text with combining marks | Send it through a PTY and through a session | It arrives byte for byte | H |
| VN-2 | Telex, VNI, and a tool that retypes with backspaces | Type in zsh and in each agent on the Mac | The words come out right, with nothing doubled or lost | hand (issue #4) |
| VN-3 | The Vietnamese keyboard on a real iPhone | Write in the message field and send | The words arrive as written | hand |

### The tests themselves

| ID | Input | Action or event | Expected response | Checked by |
|---|---|---|---|---|
| TEST-1 | A host and an app started by a test or a test script | A session starts through the login shell | Its `HOME` is the test's home folder: none of the startup files of the person running the tests is read. The hosts and apps get the test's home as `HOME`, `ZDOTDIR` and `CFFIXED_USER_HOME` | M |
| SET-1 | The Mac app's Settings left on Privacy | Left for Sessions, opened again with ⌘, | It opens on General | M |
| SET-2 | A setting the host tidies (a blank model, an unknown agent; keep awake options; the display) | A client asks for what, once tidied, the host keeps already | The asker is told what the host keeps | H |
| SET-3 | Start at Login on | The launch agent is removed outside AgentTerm | Every client is told it is off, without asking | H |
| SET-4 | The iPhone, its Mac out of reach | Look at Settings | The Mac's settings are shown as it last said and cannot be changed, and it says so; reached again, they can | P |
| SET-5 | The Mac with another Mac on screen, which has a schedule | That Mac goes out of reach | None of its schedules shows | M |

## What the tests found

Bugs that came to light while these tests were written, as a record of
what the layers are good for:

- Ending one session on the Mac (⌘W, End Session) did not ask first, though
  closing many tabs did and the iPhone always asks. It asks now (SES-10).
- The two main switches of Settings > General on the Mac had no name for
  VoiceOver: they were read as "checkbox" (AWAKE-2).
- Rows of the Mac's sidebar, of its Files tab, of its changes and of its
  History could not be pressed without a pointer; a conversation's Resume
  and Hand Off only showed under the pointer, and what a tab's or a file's
  menu holds (End Session, Close Other Tabs, Hand Off, Rename, Move to
  Trash) was only in a menu that opens under the pointer (TAB-1, TAB-4,
  FILE-2, FILE-3, GIT-4, HIST-3, HAND-6).

The review of 0.5.0 found these by reading the code. Each was then shown by
a test that failed, and fixed:

- A commit on another Mac that a slow hook refused lost its message: the
  changes read again meanwhile were taken for the commit's answer
  (REMOTE-14).
- A file on another Mac that could not be saved counted as saved, and the
  next look at the files put the old text over the changes (REMOTE-15).
- Opening the app on another Mac did not start this Mac's host
  (REMOTE-18).
- This Mac's arrangement of tabs was sent to a host that had none
  (REMOTE-16).
- Forgetting the Mac on screen with unsaved changes left it on screen and
  out of the menu (REMOTE-17).
- A title that was never ended had everything after it sent twice to a
  client that attached (SES-19), and an image too long to keep was sent in
  part and drawn as text (SES-20).
- A host started in another way, or one of a build run by hand, rewrote
  the launch agent (LOGIN-5). Another copy of the app itself still takes
  it when opened: telling that from an app that moved would mean looking
  at the path the launch agent names, which code scanning refuses.
- What an app sent while connecting again arrived before its hello, and
  the host closed the connection (SES-22).
- Each attach wrote out the whole screen again, most of a second for a
  long session, on the queue all of the host's work goes through (SES-21).

Found while #20 was built (0.6.0), each shown by a test that failed first:

- A host that was killed left the Mac app saying nothing: its sessions
  were gone and the window showed none (HOST-5). A Mac showing another Mac,
  and the iPhone, showed a list that had emptied (REMOTE-19, HOST-8).
- The app started its host again only the first time it was lost: after
  the second, it waited, then said the host did not answer (HOST-6).
- A host that could not start was tried twenty times and then reported
  with the connection's error, not the host's own reason (HOST-7).
- With the app closed, a host that was killed was not started again: the
  launch agent had no `KeepAlive`, and the iPhone could not reach the Mac
  until the app was opened (LOGIN-6).

Found while #20 was built, the third part, each shown by a test that
failed while the host reported nothing:

- A session's program that was killed closed its tab with nothing said
  (SES-23).
- A hold on sleep that macOS refused was not known to anyone (AWAKE-4).
- Usage the status line relay could not save left the usage band with
  its old figures, without a word (USE-5).

Found while #11 was built: a schedule made after its time of today ran at
once for that time (SCHED-10).

Found on CI in 0.6.0 (#32): SES-21 asked that a long session be written
out in less than 2 seconds, which held here and failed on a slower runner
(2.01 seconds). It now compares writing out a long session with writing
out a short one, and was seen to fail when each line was made to cost more
the more lines there are.

## What stays by hand

Some of this cannot be automated here, and is checked before a release:

- Anything that needs a second machine or a real phone: Tailscale between
  devices, the camera scanning a pairing code, a cellular link.
- What macOS decides: permission prompts, sleep, starting the host at
  login, the menu bar icon after the window closes.
- Real input methods (VN-2, VN-3).
- The agents' own services (USE-3): the figures need a signed-in account.
- On the iPhone, what a slow link shows (LOAD-1, LOAD-2): the test that
  drives the app waits for it to be still, which a spinner never is. It
  was looked at once by capturing the simulator from outside.
- What the Mac's terminal draws: accessibility does not give its text.
  What a session holds is checked through the host instead.
