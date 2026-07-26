from lox_helper import run_lox


def test_break_unbraced():
    # Regression test for a compiler bug where `break` behind an unbraced
    # `if (cond) break` (same scope depth as the loop body, no extra nesting)
    # failed to exit for/while/foreach loops correctly -- see
    # src/compiler/compile.go breakStatement()/forStatement().
    lines = run_lox("break_unbraced.lox")
    assert lines[:-1] == ["3", "3", "3"]
    assert lines[-1] == "nil"
