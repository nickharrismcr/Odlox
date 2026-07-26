import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["multi_break.lox", "multi_break_ns.lox"])
def test_multi_break(script):
    lines = run_lox(script)
    assert lines[0] == "10111213141516"
    assert lines[1] == "5678910111213141516"
    assert lines[2] == "10111213141516"
    assert lines[3] == "5678910111213141516"
    assert lines[-1] == "nil"
