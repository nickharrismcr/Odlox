"""Regression guards for VM/compiler crashes found via the REPL stress rig.

Each of these inputs used to trigger a Go-level panic (VM crash) instead of a
clean Lox error. They must now produce a proper error and never a panic.
"""
import pytest
from lox_helper import run_lox

# Substrings that indicate a Go-level panic leaked to output (a real crash).
CRASH_MARKERS = ("goroutine", "runtime error:", "invalid memory address",
                 "nil pointer", "index out of range")


def _assert_no_crash(lines):
    joined = "\n".join(lines)
    for marker in CRASH_MARKERS:
        assert marker not in joined, f"VM crashed (found {marker!r}):\n{joined}"


@pytest.mark.parametrize("script,expected", [
    ("mod_by_zero.lox", "Division by zero"),            # int % 0 (was: integer divide by zero panic)
    ("break_outside_loop.lox", "break outside loop"),    # was: nil pointer deref in compiler
    ("continue_outside_loop.lox", "continue outside loop"),
    ("deep_recursion.lox", "Stack overflow"),            # was: index out of range in appendStackTrace
])
def test_crash_guard(script, expected):
    lines = run_lox(script)
    _assert_no_crash(lines)
    joined = "\n".join(lines)
    assert expected in joined, f"expected {expected!r} in output:\n{joined}"
