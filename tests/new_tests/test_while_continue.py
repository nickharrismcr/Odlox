import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["while_continue.lox", "while_continue_ns.lox"])
def test_while_continue(script):
    lines = run_lox(script)
    # outer loops 3 times, inner loops 3 but skips b<2 → only "inner b" twice per outer
    assert lines.count("outer a ") == 3
    assert lines.count("inner b") == 6
    assert lines[-1] == "nil"
