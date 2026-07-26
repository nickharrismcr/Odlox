import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["type.lox", "type_ns.lox"])
def test_type(script):
    lines = run_lox(script)
    assert lines[0] == "closure"
    assert lines[1] == "class"
    assert lines[2] == "instance"
    assert lines[3] == "string"
    assert lines[4] == "int"
    assert lines[5] == "float"
    assert lines[6] == "list"
    assert lines[7] == "dict"
    assert lines[8] == "file"
    assert lines[-1] == "nil"
