import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["list_slice.lox", "list_slice_ns.lox"])
def test_list_slice(script):
    lines = run_lox(script)
    assert lines[0] == "9"
    assert lines[1] == "[ 1 , 2 , 3 , 4 , 5 , 6 , 7 , 8 , 9 ]"
    # separator
    assert lines[2] == "-" * 50
    # a[:0] == [], a[0:] == full list, a[0:1] == [1]
    assert lines[3] == "[  ]"
    assert lines[4] == "[ 1 , 2 , 3 , 4 , 5 , 6 , 7 , 8 , 9 ]"
    assert lines[5] == "[ 1 ]"
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["list_slice_assign.lox", "list_slice_assign_ns.lox"])
def test_list_slice_assign(script):
    lines = run_lox(script)
    assert lines[0] == "[ 1 , 22 , 33 , 3 , 4 , 5 ]"
    assert lines[1] == "[ 11 , 22 , 33 ]"
    assert lines[2] == "[ 1 , 1 , 6 , 7 ]"
    assert lines[-1] == "nil"
