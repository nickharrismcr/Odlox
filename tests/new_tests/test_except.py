import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["except.lox", "except_ns.lox"])
def test_except_custom_class(script):
    lines = run_lox(script)
    assert lines[0] == "hello"
    assert lines[1] == "raising MyException (something happened)"
    assert lines[2] == "in Exception handler"
    assert lines[3] == "oops MyException something happened"
    assert lines[-1] == "nil"
