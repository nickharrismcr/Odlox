import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["builtin_object_methods.lox", "builtin_object_methods_ns.lox"])
def test_builtin_object_methods(script):
    lines = run_lox(script)
    assert lines[0] == "123"
    assert lines[1] == "1|2|3"
    assert lines[2] == '[ "1" , "2" , "3" , "abc" ]'
    assert lines[3] == "a"
    assert lines[4] == "def"
    assert lines[5] == "2"
    assert lines[-1] == "nil"
