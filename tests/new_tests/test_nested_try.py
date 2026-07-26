import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["nested_try.lox", "nested_try_ns.lox"])
def test_nested_try(script):
    lines = run_lox(script)
    assert lines[0] == "hello"
    assert lines[1] == "hello inner"
    assert "inner raising" in lines[2]
    assert "in inner MyException handler" in lines[3]
    assert "inner something happened" in lines[4]
    assert "outer something happened" in lines[5]
    assert "in outer MyException handler" in lines[6]
    assert "outer something happened" in lines[7]
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["nested_try_two_handlers.lox", "nested_try_two_handlers_ns.lox"])
def test_nested_try_two_handlers(script):
    lines = run_lox(script)
    assert lines[0] == "hello"
    assert "in inner Exception handler" in lines[3]
    assert "oops Exception inner something happened" in lines[4]
    assert "in outer Exception handler" in lines[6]
    assert lines[-1] == "nil"
