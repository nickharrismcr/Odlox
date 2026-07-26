import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["fibo.lox", "fibo_ns.lox"])
def test_fibo(script):
    lines = run_lox(script)
    assert lines[0] == "55"
    assert lines[-1] == "nil"
