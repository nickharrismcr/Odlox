import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["except_fn.lox", "except_fn_ns.lox"])
def test_except_fn(script):
    lines = run_lox(script)
    assert lines[0] == "in nested raise function"
    assert lines[1] == "raising exception (something happened)"
    assert lines[2] == "in exception handler"
    assert lines[3] == "oops something happened"
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["except_fn2.lox", "except_fn2_ns.lox"])
def test_except_fn2(script):
    lines = run_lox(script)
    assert lines[0] == "in nested call"
    assert lines[1] == "in nested raise function"
    assert lines[2] == "raising exception (something happened)"
    assert lines[3] == "in exception handler"
    assert lines[4] == "oops something happened"
    assert lines[-1] == "nil"
