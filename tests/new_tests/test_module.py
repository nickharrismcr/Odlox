import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["module.lox", "module_ns.lox"])
def test_module(script):
    lines = run_lox(script)
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["module2.lox", "module2_ns.lox"])
def test_module2(script):
    lines = run_lox(script)
    assert lines[-1] == "nil"
