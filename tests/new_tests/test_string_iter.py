from lox_helper import run_lox


def test_string_iter():
    lines = run_lox("string_iter.lox")
    assert lines[:-1] == list("hello")
    assert lines[-1] == "nil"
