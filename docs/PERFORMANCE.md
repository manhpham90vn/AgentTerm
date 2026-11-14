# Performance and memory

What AgentTerm costs in the heavy cases (#21), measured rather than guessed,
so that a later change can be compared with these figures, and the
thresholds each has to meet.

## How they are taken

`scripts/measure.sh` runs `Tests/AgentTermHostTests/PerformanceMeasurements.swift`,
which makes each case in a folder of its own (a repository of 50,000 files,
a diff of 20,000 lines, a folder of 20,000 entries, 400 conversations, a
host with a state folder and port of its own), times each the shortest of
three tries, and prints `MEASURE <case>: <figure>`. Nothing fails on a
figure. `CONFIGURATION=release scripts/measure.sh` measures the build users
run. The figures below were taken on 2026-11-13 on the owner's MacBook Pro
(Apple silicon), with other work running.

## Thresholds

Approved by the owner on 2026-11-13, aiming at smooth rather than merely
fast enough: 16 ms is one frame at 60 Hz, under 100 ms feels at once, and
what takes longer works in the background while the window keeps
answering. What is over its threshold is fixed for 0.6.0.

| What | Threshold |
|---|---|
| The window, on the Mac and the iPhone | its main thread never held up more than 16 ms; heavy work in the background |
| The Git tab of a repository of 50,000 files, shown | within 500 ms |
| The side panel open, nothing changing | under 1% of a core, the app and the host together: the changes read again only when files change, not on a timer |
| 5,000 untracked files listed | within 500 ms |
| A diff of 20,000 lines opened | within 300 ms; scrolled at 60 frames a second |
| A folder of 20,000 entries listed | within 200 ms; sent to the iPhone in parts of at most 256 KB |
| A text file of 5 MB opened | within 500 ms; typing lags no more than 16 ms; a larger one says so and offers to open it anyway |
| Attaching to a session with 10,000 lines | no other session held up more than 16 ms: written out off the queue the sessions use |
| A session writing 12,000 lines at once | taken in within 50 ms |
| A history of 400 conversations listed | within 300 ms |
| The host at rest | at most 30 MB |
| Each idle session in the host | at most 1 MB |
| After 200 sessions, or tabs, opened and closed | nothing leaked (`leaks`), and what the process has allocated (`heap`) no more than 15% over what it was once the first 20 had come and gone: the pages the allocator keeps after a peak are not counted, growing with every session would be |
| A message to the iPhone or another Mac | at most 256 KB; more is sent in parts |

## Figures, before the fixes

| Case | Debug | Release | Threshold | Over it? |
|---|---|---|---|---|
| A repository of 50,000 files, nothing changed: the changes listed | 613 ms | 575 ms | within 500 ms | **yes** |
| The same, ten files changed | 608 ms | 583 ms | within 500 ms | **yes** |
| The same, the side panel open: a refresh every 3 s | 616 ms each, about 20% of a core, git's work | 582 ms each, about 19% of a core | under 1% of a core, app and host together, while nothing changes | **yes**: the changes are read again in full every 3 s |
| 5,000 untracked files (a `node_modules` not ignored) | 5.5 s | 5.1 s | within 500 ms | **yes** |
| A diff of 20,000 changed lines, a line of 1 MB and a binary: worked out | 675 ms, 781 KB of patch | 638 ms | within 300 ms | **yes** |
| The same, laid out in two panels | 22 ms | 12 ms | within 1 s, scrolling without stalling | not measured: scrolling is the app's |
| A folder of 20,000 entries: listed | 165 ms, 3.6 MB sent | 122 ms | within 200 ms, sent in parts of 256 KB | **yes**: 3.6 MB in one message |
| A text file of 5 MB | not opened: over the 2 MB limit, said to be too large | | within 1 s; typing does not lag | **cannot be measured**: there is no way to open it anyway, which #21 asks for |
| A session writing fast: 12,000 lines (1.2 MB) taken in | 173 ms | 10 ms | within 50 ms | no |
| Attaching to a session with 10,000 lines: its screen written out | 848 ms, 1 MB sent | 81 ms | no other session held up more than 16 ms | **yes**: it is written out on the queue all the host's work goes through |
| 400 conversations of 80 lines: the history listed | 361 ms | 197 ms | within 300 ms | no |
| The host at rest, no session | 16 MB | 15 MB | at most 30 MB | no |
| The host with 20 idle sessions | 23 MB, 326 KB each | 20 MB, 280 KB each | at most 1 MB for each idle session | no |
| The host after 100 sessions opened and ended | 25 MB, +50% from at rest | 24 MB, +61% | back to within 10% | **yes**, to be looked at with `leaks` and `vmmap` |

## After the first fixes

Taken again on 2026-11-13, release build, after: the changes are read with
one `git status`; new files' patches are made without a git for each; the
side panel and the host read a folder's changes again only when its files
change (FSEvents); messages larger than 256 KB are sent in pieces; and
commands are started with `posix_spawn` and waited for with `waitpid`,
since Foundation's `Process` took some 70 ms to start one and see it end
(five runs of `/usr/bin/true`: 342 ms before, 5 ms after).

| Case | Before | After | Threshold |
|---|---|---|---|
| A repository of 50,000 files, nothing changed | 575 ms | 83 ms | met |
| The same, ten files changed | 583 ms | 130 ms | met |
| The side panel open, nothing changing | a refresh every 3 s, 19% of a core | none: read again when files change | met |
| 5,000 untracked files | 5.1 s | 34 ms | met |
| A diff of 20,000 lines worked out | 638 ms | 105 ms | met |
| A folder of 20,000 entries, as sent | one message of 3.6 MB | pieces of at most 256 KB | met |
| The host after 200 sessions opened and ended | +61% of its resident size | nothing leaked; 445 KB allocated after the first 20, 479 KB after 200 (+8%) | met |
| Attaching to a session with 10,000 lines: another client waits | 89 ms, its screen written out on the queue every session uses | 0 ms: written out on the session's own queue (82 ms there) | met |
| A text file over 2 MB | cannot be opened | Open Anyway, up to 20 MB; typing in a 5 MB one not measured yet | met for opening; typing **not measured** |

## The host's memory

Taken on 2026-11-13, release build. The host at rest holds 3 MB of its own
(15 MB resident, most of it libraries every process shares). Twenty idle
sessions take some 280 KB each. Once they end, `leaks` finds nothing
leaked, yet the host holds 8 MB: in the allocator's small regions, nearly
all of it free (95%) and kept for later. Asking the allocator to hand it
back (`malloc_zone_pressure_relief`) changed nothing. The threshold was
"within 10% of where it started", which any peak of sessions breaks; it is
now that nothing leaks and that more sessions do not make it grow (PERF-8).
After 200 sessions, in four runs, it held 9, 11, 13 and 9 MB of its own,
nothing leaked each time, and what it had allocated hardly moved: 445 KB
after the first 20, 479 KB after 200. The rest is free pages the allocator
keeps, more or fewer from one run to the next. The threshold, as the owner
decided, is on what is allocated (`heap`), not on those pages (PERF-8).

## Scrolling on the iPhone

Taken on 2026-11-13 on the simulator "iPhone Air" (`SCROLL=only
scripts/test-ios.sh "iPhone Air"`, PERF-6): a terminal of 5,000 lines, a fast
swipe, and the app's processor work while it coasts, five times. The
simulator does not report late frames; a phone does.

| | Drawn on the processor | Drawn on the GPU |
|---|---|---|
| Processor time while it coasts | 0.78 s | 0.57 s |
| Instructions | 7.2 billion | 2.2 billion |
| The coast | 2.43 s | 2.42 s |

A long session is opened with 500 lines above the screen rather than all of
it, and the rest comes a page at a time as it is scrolled up (HIST-6).

## Searching files

Taken on 2026-11-14 with a debug build (`testSearchingALargeRepository`): a
repository of 50,000 small files, searched by the host (#45). The issue
asks for the first results within a second.

| | |
|---|---|
| The folder's files listed (once when the search is opened, then kept 30 s) | 250 ms |
| A name ranked among them (each key) | 173 ms |
| A word that 50 files hold: the first lines given | 63 ms |
| The same: all lines given | 660 ms |
| A word every file holds: stopped at 2,000 lines | 254 ms |

## The Mac app's main thread

Taken on 2026-11-14 with a debug build (`MEASURE=1 scripts/test-mac.sh
MainThreadMeasurements`, PERF-10). The app notes each time its main thread
took longer than a frame, 16 ms, to answer (`MainThreadWatch`, which runs
only when measuring); the test does one thing, leaves the app alone, and
reads what was noted. The threshold is that it is never held up longer
than 16 ms.

| What | Before | After | Over 16 ms still |
|---|---|---|---|
| At rest, the window open | once, 24 ms | never; in one run of five twice, the longest 49 ms | now and then |
| The Git tab shown, a change of 20,000 lines among the changes | never | never | no |
| A diff of 20,000 changed lines opened | twice, the longest 87 to 107 ms | about 12 times in the half second after, the longest 50 to 72 ms, 0.3 s in all: the tab opening, then the rest laid out in pieces | **yes** |
| That diff scrolled from top to bottom in a second | 64 to 72 times, the longest 92 ms, 4.6 s in all; only its first 4,000 lines were shown | never; every line shown | no |
| The diff laid out in two panels | twice, the longest 311 ms | twice, the longest 110 to 131 ms | **yes** |
| The two panels scrolled from top to bottom in a second | 69 times, the longest 61 ms, 3.0 s in all | the same: not changed | **yes** |
| The Files tab shown | once, 25 ms | once, 16 to 25 ms | by a little |
| A text file of 5 MB picked (it says it is large) | twice, the longest 124 ms | twice, the longest 98 to 131 ms: not changed | **yes** |
| The 5 MB file opened in the editor | 3 times, the longest 5,341 ms | once or twice, the longest 27 to 35 ms | **yes**, by 19 ms at most |
| Twenty letters typed into it, one at a time | 20 times, each about 250 ms | 3 to 5 times of the 20, the longest 19 to 25 ms | **yes**, by 9 ms at most |
| The 5 MB file scrolled from top to bottom in a second | never | never, or once, 29 to 35 ms | now and then |
| A session on show writing 12,000 lines at once | once, 20 ms | once or twice, the longest 20 to 28 ms | **yes**, by 12 ms at most |

What was changed for them:

- **The editor does not color large or plain text.** A text over 512 KB,
  and plain text of any size, gets a plain text storage: highlight.js run
  over 5 MB is what held the window for five seconds. It lays out only
  what is on show, and it no longer asks the text view for all of its text
  and compares it at each key: it keeps the text it last gave or was given.
- **The one-panel diff is one text view**, not a row for each line: a
  layout manager draws each line's tint across the pane. It is colored
  off the main thread, its top shows at once and the rest is laid out a
  piece at a time, between which the window answers; it shows the whole
  diff, where the rows stopped at 4,000 lines. When a diff on show
  changes, only what differs is put in, and the line at the top of the
  pane stays there (GIT-13).

Still over the threshold, and not changed here: the two-panel diff, which
is rows of views in code the iPhone shares (`SplitDiffView`); opening a
large diff's or a large file's tab, 50 to 130 ms; and stalls of 20 to 35
ms here and there, typing in a 5 MB file among them (9 ms over at most). The figures are of a debug build; a release build was not
measured, and neither was the iPhone app's main thread.

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
- **Scrolling a list of thousands of changes**, and the main thread of the
  iPhone app; the Mac app's is above.
