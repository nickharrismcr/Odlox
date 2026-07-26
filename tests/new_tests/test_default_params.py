from lox_helper import run_lox


def test_default_params():
    lines = run_lox("default_params.lox")
    assert lines[0] == "hi, Sam"    # greet("Sam")
    assert lines[1] == "yo, Sam"    # greet("Sam", "yo")
    assert lines[2] == "8"          # f(4)      -> m = n*2
    assert lines[3] == "10"         # f(4, 10)  -> explicit
    assert lines[4] == "[ 1 ]"      # acc(1)    -> fresh list
    assert lines[5] == "[ 2 ]"      # acc(2)    -> not shared with acc(1)
    assert lines[6] == "3x3x1"      # box(3)      -> h=w, d=1
    assert lines[7] == "3x4x1"      # box(3, 4)   -> d=1
    assert lines[8] == "3x4x5"      # box(3, 4, 5)
    assert lines[-1] == "nil"
