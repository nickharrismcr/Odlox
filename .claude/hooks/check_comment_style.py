#!/usr/bin/env python3
"""PostToolUse hook: flags debug-session narration in newly written comments.

Scans only the text a just-completed Edit/MultiEdit/Write tool call actually
introduced (not the whole file) for comments that narrate how a piece of code
came to be -- a bug hunt, a discussion, a prior version -- instead of stating
the current design/invariant as fact. See CLAUDE.md's comment conventions.

Trigger list is heuristic and intentionally editable: add/remove patterns in
TRIGGERS below as new phrasing habits show up. False positives are expected
occasionally (e.g. a legitimate "now" in unrelated prose) -- that's fine,
the cost of a false positive here is Claude re-reading one comment.
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


def comment_lines(text):
    for i, line in enumerate(text.splitlines(), start=1):
        s = line.strip()
        if s.startswith(COMMENT_PREFIXES):
            yield i, s


def scan(text, pattern):
    hits = []
    for lineno, line in comment_lines(text):
        m = pattern.search(line)
        if m:
            hits.append((lineno, line, m.group(0)))
    return hits


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

    all_hits = []
    for text in texts_from_input(data):
        all_hits.extend(scan(text, pattern))

    if not all_hits:
        return 0

    lines_report = "\n".join(
        f"  line ~{n}: matched {trig!r} in: {line}" for n, line, trig in all_hits
    )
    message = (
        f"Comment style check flagged {file_path}:\n{lines_report}\n\n"
        "Rewrite these comments to state the current design/invariant as "
        "fact -- not how it was found, discussed, or changed. No 'used to "
        "X', 'an earlier version', 'see git history', 'we discussed', "
        "'now warns'. State what IS true, not the history of how it got "
        "that way. See CLAUDE.md / feedback_comment_style_odlox memory."
    )
    print(json.dumps({
        "systemMessage": f"Comment style check: {len(all_hits)} flagged line(s) in {file_path}",
        "additionalContext": message,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
