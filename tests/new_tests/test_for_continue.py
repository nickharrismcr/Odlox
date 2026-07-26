import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["for_continue.lox", "for_continue_ns.lox"])
def test_for_continue(script):
    lines = run_lox(script)
    assert lines[:-1] == ["0", "1", "2", "3", "4", "5"]
    assert lines[-1] == "nil"
