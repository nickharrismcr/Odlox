import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["tuples.lox", "tuples_ns.lox"])
def test_tuples(script):
    lines = run_lox(script)
    # foreach over (1,2,3,4,5,6)
    assert lines[:6] == ["1", "2", "3", "4", "5", "6"]
    # tuple concatenation
    assert lines[6] == "[ 1 , 2 , 3 , 7 , 8 , 9 ]"
    # append(2, a) raises RuntimeError — tuples are immutable (append expects list as first arg)
    assert "Uncaught exception" in lines[-1]
    assert "append" in lines[-1].lower() or "list" in lines[-1].lower()
