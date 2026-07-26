import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["finally_bare.lox", "finally_bare_ns.lox"])
def test_finally_bare(script):
    # Bare try/finally with no except clause -- previously a parse error.
    lines = run_lox(script)
    assert lines == ["body", "cleanup", "after", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_finally_except_normal(force_compile):
    # Nothing raised: finally runs once, on the normal-completion path.
    lines = run_lox("finally_except_normal.lox", force_compile=force_compile)
    assert lines == ["body", "cleanup", "after", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_finally_except_match(force_compile):
    # Exception caught by an except clause: finally still runs once, after
    # that clause's own body.
    lines = run_lox("finally_except_match.lox", force_compile=force_compile)
    assert lines == ["caught", "cleanup", "after", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_finally_uncaught(force_compile):
    # No except clause here at all: finally still runs before the exception
    # keeps propagating, and an outer try can still catch it afterward.
    lines = run_lox("finally_uncaught.lox", force_compile=force_compile)
    assert lines == ["inner cleanup", "caught by outer", "after", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_finally_return(force_compile):
    # return inside a try/finally runs cleanup before actually returning,
    # and still returns the correct value.
    lines = run_lox("finally_return.lox", force_compile=force_compile)
    assert lines == ["cleanup", "42", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_finally_break_continue(force_compile):
    # break/continue crossing a try/finally inside a loop must run cleanup
    # exactly once per crossing (and once per ordinary completed iteration).
    lines = run_lox("finally_break_continue.lox", force_compile=force_compile)
    assert lines == [
        "body 0",
        "cleanup 0",
        "cleanup 1",
        "body 2",
        "cleanup 2",
        "cleanup 3",
        "done",
        "nil",
    ]


@pytest.mark.parametrize("force_compile", [False, True])
def test_finally_supersede(force_compile):
    # A new exception raised inside finally supersedes the one already
    # propagating -- the enclosing except clause catches the new one.
    lines = run_lox("finally_supersede.lox", force_compile=force_compile)
    assert lines == ["caught BarError (correct)", "after", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_finally_nested(force_compile):
    # Nested try/finally: inner cleanup runs before outer cleanup, and the
    # return value still comes through correctly.
    lines = run_lox("finally_nested.lox", force_compile=force_compile)
    assert lines == ["inner cleanup", "outer cleanup", "deep", "nil"]
