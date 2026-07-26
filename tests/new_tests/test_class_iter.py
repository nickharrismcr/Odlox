from lox_helper import run_lox


def test_class_iter():
    lines = run_lox("class_iter.lox")
    # sum of range(1,10) = 1+2+...+9 = 45
    assert lines[0] == "45"
    assert lines[-1] == "nil"
