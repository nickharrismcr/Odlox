import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["str_class_toString.lox", "str_class_toString_ns.lox"])
def test_str_class_tostring(script):
    lines = run_lox(script)
    assert lines[0] == "<class A>"
    assert lines[1] == "A toString = hello"
    assert lines[2] == "A toString = hello"
    assert lines[3] == "1"
    assert lines[4] == "hello"
    assert lines[5] == "1"
    assert lines[6] == "1"
    assert lines[7] == "[ 1 , 2 , 3 ]"
    assert lines[-1] == "nil"
