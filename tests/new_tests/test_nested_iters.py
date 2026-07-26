from lox_helper import run_lox


def test_nested_iters():
    lines = run_lox("nested_iters.lox")
    assert lines[0] == "7920200"
    assert lines[-1] == "nil"
