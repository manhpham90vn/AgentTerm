#!/usr/bin/python3
"""A stand-in for an agent, for the screenshots.

scripts/screenshots.sh puts this under the agents' names. Started in a
terminal it draws what an agent's screen looks like after one answer, and
draws it again for the new width whenever the terminal is resized, as the
real ones do. Nothing is asked of any service and no account is used.

As `claude` it also reports usage the way Claude Code does, through the
status line command it was started with, so the usage band has figures.
"""
import json
import os
import re
import sys
import textwrap
import time

NAME = os.path.basename(sys.argv[0])
ESC = "\x1b["
DIM, BOLD, RESET = ESC + "2m", ESC + "1m", ESC + "0m"

ASK = "Explain in short lines how Parser.parse works and which edge cases the tests should cover."
ANSWER = [
    ("How parse works", [
        "It takes one line of text and returns an array of strings.",
        "First it splits the text on every comma.",
        "The split uses Swift's default, which drops empty pieces.",
        "So \"a,,b\" yields two fields, not three.",
        "Leading and trailing commas also vanish for the same reason.",
        "Each remaining piece is then trimmed with the whitespaces set.",
        "That set covers spaces, tabs and other Unicode horizontal spaces.",
        "Trimming only touches the ends; spaces inside a field are kept.",
        "There is no quote handling: a comma inside quotes still splits.",
        "There is no escaping, and nothing ever throws.",
    ]),
    ("Edge cases the tests should cover", [
        "Spaces before, after and on both sides of a field.",
        "Tabs around a field.",
        "Inner spaces preserved, for example \"a b\" staying intact.",
        "Empty string input returns an empty array.",
        "Input with no commas returns one trimmed field.",
        "Consecutive commas: pin down that empty fields are dropped.",
        "A field of only spaces: pin down the empty string result.",
        "Quoted field containing a comma, to document that it splits.",
    ]),
]
CLOSING = (
    "The dropped empty fields are the part most likely to be a bug rather than intended: if column "
    "positions matter, every later column shifts. Decide what you want there before writing tests "
    "that lock it in."
)
NEXT = "add tests for those edge cases"


def size():
    try:
        return os.get_terminal_size(sys.stdout.fileno())
    except OSError:
        return os.terminal_size((80, 24))


def report_usage():
    """What Claude Code tells its status line: the model, the context, the limits."""
    if "--settings" not in sys.argv:
        return
    try:
        settings = json.loads(sys.argv[sys.argv.index("--settings") + 1])
        found = re.search(r" statusline '(.+)'$", settings["statusLine"]["command"])
        if not found:
            return
        now = time.time()
        week = now + 2 * 86400 - (now % 86400) + 4 * 3600
        report = {
            "model": {"display_name": "Fable 5.2"},
            "context_window": {"context_window_size": 1_000_000, "used_percentage": 5},
            "rate_limits": {
                "five_hour": {"used_percentage": 12, "resets_at": now + 4 * 3600 + 28 * 60},
                "seven_day": {"used_percentage": 38, "resets_at": week},
            },
        }
        os.makedirs(os.path.dirname(found.group(1)), exist_ok=True)
        with open(found.group(1), "w") as file:
            json.dump(report, file)
    except (ValueError, KeyError, IndexError, OSError):
        pass


def claude(cols):
    out = []
    width = max(cols - 4, 20)
    asked = textwrap.wrap(ASK, width)
    for index, line in enumerate(asked):
        out.append(ESC + "48;5;237m" + (DIM + "❯ " + RESET + ESC + "48;5;237m" if index == 0 else "  ") + line.ljust(cols - 2) + RESET)
    out.append("")
    number = 0
    for index, (title, lines) in enumerate(ANSWER):
        out.append(("● " if index == 0 else "  ") + BOLD + title + RESET)
        out.append("")
        for line in lines:
            number += 1
            label = f"{number}. "
            wrapped = textwrap.wrap(line, max(width - len(label) - 2, 10))
            out.append("  " + label + wrapped[0])
            out.extend("  " + " " * len(label) + more for more in wrapped[1:])
        out.append("")
    out.extend("  " + line for line in textwrap.wrap(CLOSING, width))
    out.append("")
    out.append(DIM + "✻ Baked for 10s · done " + time.strftime("%-I:%M %p") + RESET)
    out.append("")
    rule = DIM + "─" * cols + RESET
    out.append(rule)
    out.append("❯ " + ESC + "7m" + NEXT[0] + ESC + "27m" + DIM + NEXT[1:] + RESET)
    out.append(rule)
    hint = " (shift+tab to cycle)" if cols >= 46 else ""
    out.append("  " + ESC + "33m⏵⏵ auto mode on" + RESET + DIM + hint + RESET)
    return out


def other(cols):
    names = {"codex": "Codex", "agy": "Antigravity", "copilot": "Copilot CLI"}
    return [BOLD + names.get(NAME, NAME) + RESET, DIM + os.path.basename(os.getcwd()) + RESET, "", "❯ "]


def draw(cols, rows):
    lines = claude(cols) if NAME == "claude" else other(cols)
    # The end of it is what shows, as in a terminal that scrolled.
    sys.stdout.write(ESC + "?25l" + ESC + "H" + ESC + "2J" + "\r\n".join(lines[-max(rows - 1, 1):]))
    sys.stdout.flush()


def main():
    # Asked for one answer, as when the app has an agent write a commit message.
    if "-p" in sys.argv or "exec" in sys.argv[1:2]:
        sys.stdin.read()
        print("feat: trim the spaces around each field")
        return
    if NAME == "claude":
        report_usage()
    os.system("stty -echo 2>/dev/null")
    # Drawn again whenever the terminal has another size. Looked at now and
    # then rather than on the signal: a signal in the middle of drawing
    # would leave the screen half drawn.
    drawn = None
    while True:
        now = size()
        if now != drawn:
            drawn = now
            draw(now.columns, now.lines)
        time.sleep(0.2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
