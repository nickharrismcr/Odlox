import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["while_break.lox", "while_break_ns.lox"])
def test_while_break(script):
    lines = run_lox(script)
    # a goes 1..5 printing a, B, C; then a=6 prints just "6" then breaks
    assert lines[0] == "1"
    assert lines[1] == "B"
    assert lines[2] == "C"
    assert lines[-2] == "6"
    assert lines[-1] == "nil"
    assert "B" not in lines[lines.index("6"):]
