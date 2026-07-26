import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["list_index.lox", "list_index_ns.lox"])
def test_list_index(script):
    lines = run_lox(script)
    assert lines[0] == "5"
    assert lines[1:6] == ["111", "222", "333", "444", "555"]
    assert lines[6] == "555"   # a[-1]
    assert lines[7] == "6"
    assert lines[8:14] == ["11", "22", "33", "44", "55", "66"]
    assert lines[14:20] == ["66", "55", "44", "33", "22", "11"]  # reversed
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["list_index_assign.lox", "list_index_assign_ns.lox"])
def test_list_index_assign(script):
    lines = run_lox(script)
    assert lines[0] == "[ 1 , 2 , 3 , 4 ]"
    assert lines[1] == "[ 11 , 22 , 33 , 44 ]"
    assert lines[2] == "[ 44 , 33 , 22 , 11 ]"
    assert lines[-1] == "nil"
