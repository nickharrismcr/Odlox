import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["in.lox", "in_ns.lox"])
def test_in_operator(script):
    lines = run_lox(script)
    assert lines[0] == "hello world"
    assert lines[1] == "true"    # "hello" in string
    assert lines[2] == "false"   # "x" not in string
    assert lines[3] == "true"    # variable in string
    assert lines[4] == '[ "hello" , "world" ]'
    assert lines[5] == "true"    # "hello" in list
    assert lines[6] == "false"   # 2 not in list
    assert lines[7] == "false"   # b=2 not in list
    assert lines[8] == "true"    # "a" in dict keys
    assert lines[9] == "false"   # "X" not in dict keys
    assert lines[-1] == "nil"
