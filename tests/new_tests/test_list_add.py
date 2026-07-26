import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["list_add.lox", "list_add_ns.lox"])
def test_list_add(script):
    lines = run_lox(script)
    assert lines[0] == '[ 1 , 2 , 3 , 4 , "a" , "b" , "c" , "d" ]'
    assert lines[-1] == "nil"
