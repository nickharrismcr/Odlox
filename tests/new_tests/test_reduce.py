import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["reduce.lox", "reduce_ns.lox"])
def test_reduce(script):
    lines = run_lox(script)
    assert lines[0] == "15"
    assert lines[-1] == "nil"
