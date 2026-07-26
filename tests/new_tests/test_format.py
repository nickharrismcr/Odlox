from lox_helper import run_lox


def test_format():
    lines = run_lox("format.lox")
    assert lines[0] == "1 2.200000 hello world"
    assert lines[-1] == "nil"
