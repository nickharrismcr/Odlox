import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["inheritance.lox", "inheritance_ns.lox"])
def test_inheritance(script):
    lines = run_lox(script)
    assert lines[0] == "hello"
    assert lines[1] == "hello"
    assert lines[-1] == "nil"
