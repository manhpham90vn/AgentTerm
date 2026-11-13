# CLAUDE.md

Guidance for Claude Code, and any other coding agent, working in this repository.

Read first: `README.md`, `docs/SPEC.md` (what the app does), `docs/DESIGN.md` (how it is built), `docs/TESTING.md` (how it is tested). What is planned is in the GitHub issues and milestones; issue #28 says how the releases fit together and what was decided.

## Rules

### 1. Important decisions are asked, not made

When the work reaches a decision that matters, stop and ask the owner. Say what the choices are, what each costs, and which one you would take, then wait for the answer. Do not pick one and report it afterwards.

A decision matters when it is any of these:

- **What the app does.** Adding, removing or changing a behaviour the user can see, or trading one behaviour for another: a fix that makes one case work by giving up another is a decision, not a fix.
- **Scope.** Doing more than was asked, or less. Leaving part of a task undone, or solving it only in part.
- **Design.** A new protocol message or a change to one, a new dependency, a new component, where data is kept, anything `docs/DESIGN.md` would have to describe differently.
- **Security and privacy.** Dismissing or working around a code scanning alert, widening what a client or a plugin may do, anything that touches tokens, pairing, or what is sent off the machine.
- **Planning.** Which release an issue belongs to, what is in or out of a milestone, closing an issue, what is said in release notes.
- **Anything outward or hard to undo.** Committing, pushing, opening or merging a pull request, releasing, creating or editing issues and milestones, deploying, deleting. Each is done when asked, and being asked once is not being asked for the next time.
- **Anything of the user's own.** Their installed app, its sessions, its preferences, its paired devices, their simulators, their accounts.

Not decisions to ask about: how to name a local variable, which of two equal ways to write a loop, the order of tests in a file. When unsure whether something matters, it does: ask.

If a choice was made without asking, say so plainly in the report, with what was chosen and what the other choices were, so it can be undone.

### 2. Work that is done is tested in full

Nothing is reported as done before it has been tested, and the report says what was run and what came of it.

- **A bug is shown before it is fixed.** Write a test that fails because of the bug, run it and see it fail, fix the bug, run it again and see it pass. The test stays. A bug that cannot be shown by a test is said to be so, with what was done instead.
- **Every layer the change touches is run**, as `docs/TESTING.md` says under "Running them":

  | Changed | Run |
  |---|---|
  | Anything | `swift build` and `swift test` |
  | The Mac app, or anything it uses | `scripts/test-mac.sh` |
  | The iPhone app, or code shared with it (`AgentTermClient`, `AgentTermProtocol`, `AgentTermTerminal`, `AgentTermEditor`) | `scripts/test-ios.sh "iPhone Air"` |
  | What one app shows of what the other did | `scripts/test-both.sh "iPhone Air"` |
  | What a picture shows (toolbar, lists, the terminal) | `scripts/screenshots.sh`, and look at each picture |

  Before a release, all of them.
- **A change to what is seen is looked at.** Take a picture of the window (`SHOTS=... ALL_SHOTS=1 scripts/test-mac.sh <test>`) and look at it; a build that compiles has not been seen.
- **A new behaviour gets a case** in `docs/TESTING.md` and a test that names it.
- **The report is true.** Which commands ran, which passed and which failed, with the failing output. What was not run is said, with why: "not tested on the iPhone" is an acceptable sentence, silence about it is not. A check that is skipped ("Executed 0 tests", tests listed as skipped) checked nothing and is not reported as passing.
- **Tests that fail are not made to pass** by weakening them, skipping them or deleting them. If a test is wrong, say why and ask (rule 1).

### 3. Nothing of the user's is touched while testing

- Hosts and apps run for a test use a state folder (`AGENTTERM_STATE_DIR`), a port (`AGENTTERM_PORT`) and a home folder of their own, never `~/Library/Application Support/AgentTerm` or the installed app's port.
- An app's preferences are kept under its bundle identifier, whatever home folder it is given. A copy of the app built for a test gets an identifier of its own (`IDENTIFIER=... scripts/bundle-mac.sh`), and is never built into `dist/`, where a copy may be running.
- The iPhone tests reset the keychain of the simulator they run in: use "iPhone Air", not a simulator an app is paired in.
- No pairing code, token or other secret is printed.

## Conventions

- Code, comments, commit messages and everything under `docs/` are in English. Commit messages follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).
- No force push, no rewriting of history, no deleting of branches.
- Work happens on the milestone's branch and reaches `main` through a pull request.
