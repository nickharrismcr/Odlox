import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["closure.lox", "closure_ns.lox"])
def test_closure_basic(script):
    lines = run_lox(script)
    assert lines[0] == "outside"
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["closure2.lox", "closure2_ns.lox"])
def test_closure_nested(script):
    lines = run_lox(script)
    assert lines[0] == "outside added"
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["closure_list.lox", "closure_list_ns.lox"])
def test_closure_in_list(script):
    lines = run_lox(script)
    assert lines[:-1] == [str(i) for i in range(10)]
    assert lines[-1] == "nil"
