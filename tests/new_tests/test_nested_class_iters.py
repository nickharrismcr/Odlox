from lox_helper import run_lox


def test_nested_class_iters():
    lines = run_lox("nested_class_iters.lox")
    # nested loops over range(1,100) twice: sum of (i+j) for i,j in [1..99]
    assert lines[0] == "980100"
    assert lines[-1] == "nil"
