import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["for_break.lox", "for_break_ns.lox"])
def test_for_break(script):
    lines = run_lox(script)
    assert lines[:-1] == ["1", "2", "3", "4", "5"]
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["for_break_nested.lox", "for_break_nested_ns.lox"])
def test_for_break_nested(script):
    lines = run_lox(script)
    # Outer loop breaks at a>5; inner loop breaks at aa>5.
    # a=6 prints "6" once (the print before the `if (a>5) break`), then the
    # outer loop exits for good -- it must not reach a=7.
    assert "6" in lines
    assert "7" not in lines
    assert lines[-1] == "nil"
    # a=1..5 each print a twice (before and after the inner loop); a=6 prints once.
    assert lines.count("1") == 2
    assert lines.count("6") == 1
