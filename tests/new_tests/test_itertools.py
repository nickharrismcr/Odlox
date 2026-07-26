import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["itertools.lox", "itertools_ns.lox"])
def test_itertools_reverse(script):
    lines = run_lox(script)
    assert lines[0] == "4321"
    assert lines[1] == "[ 4 , 3 , 2 , 1 ]"
    assert lines[-1] == "nil"
