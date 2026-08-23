#!/usr/bin/env python3
"""PostToolUse hook: flags debug-session narration and overlong comments.

Scans only the text a just-completed Edit/MultiEdit/Write tool call actually
introduced (not the whole file) for two problems: (1) comments that narrate
how a piece of code came to be -- a bug hunt, a discussion, a prior version
-- instead of stating the current design/invariant as fact, and (2) comments
that are too long, either a single overlong line or a multi-line block,
where the project convention is one short line stating a non-obvious WHY.
See CLAUDE.md's comment conventions.

Trigger list and length thresholds are heuristic and intentionally
editable: adjust as new phrasing habits or false positives show up.
"""
import json
import re
import sys

TRIGGERS = [
    r"\bused to (crash|segfault|fail|break|hang|warn|not work)\b",
    r"\ban earlier (version|implementation|attempt|pass)\b",
    r"\b(see|check) git (history|log)\b",
    r"\bfor the full story\b",
    r"\bformer (hand-written|implementation|version|special case)\b",
    r"\bbefore this (feature|table|change|fix|commit) existed\b",
    r"\bwe (discussed|found|debugged|decided|tried)\b",
    r"\b(during|while) (debugging|the investigation|this session)\b",
    r"\b(fixed|found) a (real )?(bug|crash|segfault|regression)\b",
    r"\bpreviously (was|did|used)\b",
    r"\bas (discussed|requested|per (your|the user))\b",
    r"\bthe user (asked|wanted|said)\b",
    r"\bnow (warns?|prints?|also (does|warns?|checks?)|does this)\b",
    r"\bthis (bug|crash|segfault) (was|is)\b",
    r"\bturned out to be\b",
]

COMMENT_PREFIXES = ("//", "#", "--", "/*", "*", ";")

MAX_COMMENT_LINE_CHARS = 100
MAX_COMMENT_BLOCK_LINES = 3


def comment_lines(text):
    for i, line in enumerate(text.splitlines(), start=1):
        s = line.strip()
        if s.startswith(COMMENT_PREFIXES):
            yield i, s


def comment_blocks(text):
    """Groups consecutive comment lines into blocks (start, end, lines)."""
    lines = text.splitlines()
    blocks = []
    current = []
    current_start = None
    for i, line in enumerate(lines, start=1):
        s = line.strip()
        if s.startswith(COMMENT_PREFIXES):
            if not current:
                current_start = i
            current.append(s)
        else:
            if current:
                blocks.append((current_start, i - 1, current))
                current = []
    if current:
        blocks.append((current_start, len(lines), current))
    return blocks


def scan_triggers(text, pattern):
    hits = []
    for lineno, line in comment_lines(text):
        m = pattern.search(line)
        if m:
            hits.append((lineno, line, m.group(0)))
    return hits


def scan_overlong(text):
    long_lines = []
    long_blocks = []
    for lineno, line in comment_lines(text):
        if len(line) > MAX_COMMENT_LINE_CHARS:
            long_lines.append((lineno, len(line), line))
    for start, end, lines in comment_blocks(text):
        if len(lines) > MAX_COMMENT_BLOCK_LINES:
            long_blocks.append((start, end, len(lines)))
    return long_lines, long_blocks


def texts_from_input(data):
    ti = data.get("tool_input", {}) or {}
    tool = data.get("tool_name", "")
    if tool == "Edit":
        for key in ("new_string", "new_str"):
            if key in ti:
                yield ti[key]
                return
    elif tool == "MultiEdit":
        for e in ti.get("edits", []) or []:
            for key in ("new_string", "new_str"):
                if key in e:
                    yield e[key]
                    break
    elif tool == "Write":
        for key in ("content", "file_text"):
            if key in ti:
                yield ti[key]
                return


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    file_path = (data.get("tool_input", {}) or {}).get("file_path", "<unknown>")
    pattern = re.compile("|".join(TRIGGERS), re.IGNORECASE)

    trigger_hits = []
    long_lines = []
    long_blocks = []
    for text in texts_from_input(data):
        trigger_hits.extend(scan_triggers(text, pattern))
        ll, lb = scan_overlong(text)
        long_lines.extend(ll)
        long_blocks.extend(lb)

    if not trigger_hits and not long_lines and not long_blocks:
        return 0

    sections = []
    total = 0

    if trigger_hits:
        total += len(trigger_hits)
        lines_report = "\n".join(
            f"  line ~{n}: matched {trig!r} in: {line}" for n, line, trig in trigger_hits
        )
        sections.append(
            "Narration (states history, not current design):\n" + lines_report + "\n"
            "Rewrite to state the current design/invariant as fact -- not how it "
            "was found, discussed, or changed. No 'used to X', 'an earlier "
            "version', 'see git history', 'we discussed', 'now warns'."
        )

    if long_lines:
        total += len(long_lines)
        lines_report = "\n".join(
            f"  line {n}: {length} chars: {line}" for n, length, line in long_lines
        )
        sections.append(
            f"Overlong comment line(s) (>{MAX_COMMENT_LINE_CHARS} chars):\n" + lines_report + "\n"
            "Trim to a single short line, or drop the comment if it's not "
            "stating a genuinely non-obvious WHY."
        )

    if long_blocks:
        total += len(long_blocks)
        lines_report = "\n".join(
            f"  lines {start}-{end}: {n} consecutive comment lines" for start, end, n in long_blocks
        )
        sections.append(
            f"Overlong comment block(s) (>{MAX_COMMENT_BLOCK_LINES} lines):\n" + lines_report + "\n"
            "Convention is one short line max stating a non-obvious WHY, not a "
            "multi-line explanation. Cut it down."
        )

    message = f"Comment style check flagged {file_path}:\n\n" + "\n\n".join(sections) + (
        "\n\nSee CLAUDE.md / feedback_comment_style_odlox memory."
    )
    print(json.dumps({
        "systemMessage": f"Comment style check: {total} flagged item(s) in {file_path}",
        "additionalContext": message,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
