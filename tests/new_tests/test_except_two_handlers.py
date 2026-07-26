import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["except_two_handlers.lox", "except_two_handlers_ns.lox"])
def test_two_handlers_routes_to_base(script):
    lines = run_lox(script)
    assert lines[0] == "hello"
    assert lines[1] == "raising Exception (something happened)"
    assert lines[2] == "in Exception handler"
    assert lines[3] == "oops Exception something happened"
    assert lines[-1] == "nil"
