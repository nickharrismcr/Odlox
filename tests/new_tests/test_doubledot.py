import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["doubledot.lox", "doubledot_ns.lox"])
def test_doubledot_chained_method_call(script):
    lines = run_lox(script)
    assert lines[0] == "Avalue"
    assert lines[-1] == "nil"
