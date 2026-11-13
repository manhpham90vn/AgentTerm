# Performance and memory

What AgentTerm costs in the heavy cases (#21), measured rather than guessed,
so that a later change can be compared with these figures. In 0.6.0 every
case is measured and nothing is fixed yet: the thresholds are proposed from
the figures below and approved by the owner, and only then is what is over
them fixed (see #21).

## How they are taken

`scripts/measure.sh` runs `Tests/AgentTermHostTests/PerformanceMeasurements.swift`,
which makes each case in a folder of its own (a repository of 50,000 files,
a diff of 20,000 lines, a folder of 20,000 entries, 400 conversations, a
host with a state folder and port of its own), times each the shortest of
three tries, and prints `MEASURE <case>: <figure>`. Nothing fails on a
figure. `CONFIGURATION=release scripts/measure.sh` measures the build users
run. The figures below were taken on 2026-11-13 on the owner's MacBook Pro
(Apple silicon), with other work running.

## Figures

| Case | Debug | Release | Proposed threshold | Over it? |
|---|---|---|---|---|
| A repository of 50,000 files, nothing changed: the changes listed | 613 ms | 575 ms | within 1 s | no |
| The same, ten files changed | 608 ms | 583 ms | within 1 s | no |
| The same, the side panel open: a refresh every 3 s | 616 ms each, about 20% of a core, git's work | 582 ms each, about 19% of a core | under 2% of a core, app and host together, while nothing changes | **yes**: the changes are read again in full every 3 s |
| 5,000 untracked files (a `node_modules` not ignored) | 5.5 s | 5.1 s | within 1 s | **yes** |
| A diff of 20,000 changed lines, a line of 1 MB and a binary: worked out | 675 ms, 781 KB of patch | 638 ms | within 1 s | no |
| The same, laid out in two panels | 22 ms | 12 ms | within 1 s, scrolling without stalling | not measured: scrolling is the app's |
| A folder of 20,000 entries: listed | 165 ms, 3.6 MB sent | 122 ms | within 1 s | no; what is sent to the iPhone is large |
| A text file of 5 MB | not opened: over the 2 MB limit, said to be too large | | within 1 s; typing does not lag | **cannot be measured**: there is no way to open it anyway, which #21 asks for |
| A session writing fast: 12,000 lines (1.2 MB) taken in | 173 ms | 10 ms | | |
| Attaching to a session with 10,000 lines: its screen written out | 848 ms, 1 MB sent | 81 ms | the host's other sessions not held up more than 100 ms | no in a release build, close to it; yes in a debug build. It is written out on the queue all the host's work goes through |
| 400 conversations of 80 lines: the history listed | 361 ms | 197 ms | within 1 s | no |
| The host at rest, no session | 16 MB | 15 MB | | |
| The host with 20 idle sessions | 23 MB, 326 KB each | 20 MB, 280 KB each | under 10 MB for each idle session | no |
| The host after 100 sessions opened and ended | 25 MB, +50% from at rest | 24 MB, +61% | back to within 10% | **yes**, to be looked at with `leaks` and `vmmap` |

## Not measured yet

These need what a test on this Mac does not have, and are still to do for
#21:

- **The iPhone, and a Mac showing another Mac**, for every case above: what
  is sent, how large, and whether the app stays usable meanwhile. They get
  everything through the host, so the sizes above (3.6 MB for the folder,
  1 MB for an attach) are what they receive.
- **A slow link**: the same over a weak connection.
- **Memory over a day or more** of the app and the host left running with
  sessions that keep writing; and the Mac app's own memory after opening
  and closing files, diffs and previews a hundred times, and switching
  between Macs.
- **Leaks** under Instruments (Leaks, Allocations) or `leaks` on the running
  process, for the host's growth after 100 sessions above.
- **Scrolling** a diff of 20,000 lines and a list of thousands of changes,
  which is the app's drawing rather than the host's.
