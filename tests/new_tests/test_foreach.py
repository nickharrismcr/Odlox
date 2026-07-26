import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["foreach.lox", "foreach_ns.lox"])
def test_foreach_break(script):
    lines = run_lox(script)
    assert lines[0] == "[ 1 , 2 , 3 , 4 , 5 , 6 , 7 , 8 , 9 , 10 , 11 , 12 , 13 , 14 , 15 , 16 , 17 , 18 , 19 ]"
    assert lines[1:6] == ["1", "2", "3", "4", "5"]
    # squares of 1..5
    assert lines[6:11] == ["1", "4", "9", "16", "25"]
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["foreach_continue.lox", "foreach_continue_ns.lox"])
def test_foreach_continue(script):
    lines = run_lox(script)
    assert lines[0] == "[ 1 , 2 , 3 , 4 , 5 , 6 , 7 , 8 , 9 , 10 ]"
    assert lines[1:-1] == ["5", "6", "7", "8", "9", "10"]
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["nested_foreach.lox", "nested_foreach_ns.lox"])
def test_nested_foreach(script):
    lines = run_lox(script)
    # 9-char string, iterates building cumulative strings; 54 content lines + nil
    assert len(lines) == 55
    assert lines[0] == "1"
    assert lines[1] == ">1"
    assert lines[2] == "12"
    assert lines[3] == ">11"
    assert lines[-1] == "nil"
